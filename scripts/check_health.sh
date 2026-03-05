#!/bin/bash
set -euo pipefail

# ============================================================
# Canton Validator Toolkit — check_health.sh
# Health check + Telegram alerts with state machine
# (no spam: alert once on failure, once on recovery)
# ============================================================

CANTON_DIR="$HOME/.canton"
TOOLKIT_CONF="$CANTON_DIR/toolkit.conf"
STATE_DIR="$CANTON_DIR/health"
STATE_FILE="$STATE_DIR/state"
MSGID_FILE="$STATE_DIR/msgid"

log()     { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
success() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✓ $1"; }
warn()    { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠ $1"; }
error()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✗ $1" >&2; }

# ============================================================
# Load config
# ============================================================
if [ ! -f "$TOOLKIT_CONF" ]; then
    error "toolkit.conf not found: $TOOLKIT_CONF — run setup.sh first"
    exit 1
fi
# shellcheck source=/dev/null
source "$TOOLKIT_CONF"

TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
NODE_NAME="${NODE_NAME:-Canton-Validator}"
AUTO_RESTART="${AUTO_RESTART:-true}"

SYNC_LAG_WARN=60      # seconds — warning threshold
SYNC_LAG_CRIT=120     # seconds — critical threshold
RETRY_FAIL_THRESH=10  # splice_retries_failures threshold
DISK_WARN_GB=20       # GB free — warning threshold

mkdir -p "$STATE_DIR"

# ============================================================
# Telegram
# ============================================================
send_telegram() {
    [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ] && return 0
    local response
    response=$(curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TELEGRAM_CHAT_ID}" \
        -d parse_mode="HTML" \
        -d text="$1" 2>/dev/null) || return 0
    echo "$response" | grep -oP '"message_id":\K[0-9]+' || true
}

pin_message() {
    [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ] && return 0
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/pinChatMessage" \
        -d chat_id="${TELEGRAM_CHAT_ID}" \
        -d message_id="$1" \
        -d disable_notification=false > /dev/null 2>&1 || true
}

unpin_message() {
    [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ] && return 0
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/unpinChatMessage" \
        -d chat_id="${TELEGRAM_CHAT_ID}" \
        -d message_id="$1" > /dev/null 2>&1 || true
}

# ============================================================
# Container checks
# ============================================================
check_containers() {
    local issues=""

    # Detect container names dynamically (works for mainnet/testnet/devnet prefixes)
    local validator_c participant_c nginx_c
    validator_c=$(docker ps -a --format '{{.Names}}' | grep -E 'validator-1$' | grep -v postgres | head -1)
    participant_c=$(docker ps -a --format '{{.Names}}' | grep -E 'participant-1$' | head -1)
    nginx_c=$(docker ps -a --format '{{.Names}}' | grep -E 'nginx-1$' | head -1)

    for container in $validator_c $participant_c $nginx_c; do
        [ -z "$container" ] && continue
        local running health
        running=$(docker inspect --format='{{.State.Running}}' "$container" 2>/dev/null || echo "false")
        health=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "not_found")

        if [ "$running" != "true" ]; then
            issues="${issues}🔴 ${container}: DOWN\n"

            if [ "$AUTO_RESTART" = "true" ]; then
                warn "Auto-restarting $container..."
                docker start "$container" 2>/dev/null || true
            fi
        elif [ "$health" != "healthy" ] && [ "$health" != "" ]; then
            issues="${issues}🟡 ${container}: ${health}\n"

            if [ "$AUTO_RESTART" = "true" ] && [ "$health" = "unhealthy" ]; then
                warn "Restarting unhealthy $container..."
                docker restart "$container" 2>/dev/null || true
            fi
        fi
    done

    echo -n "$issues"
}

# ============================================================
# Sync lag check (via metrics port directly)
# ============================================================
check_sync_lag() {
    local issues=""

    local metrics
    metrics=$(curl -sf --max-time 5 \
        -H "Host: validator.localhost" \
        "http://127.0.0.1:8888/metrics" 2>/dev/null || echo "")

    if [ -z "$metrics" ]; then
        # Try direct container port
        metrics=$(curl -sf --max-time 5 \
            "http://127.0.0.1:10013/metrics" 2>/dev/null || echo "")
    fi

    if [ -z "$metrics" ]; then
        issues="${issues}⚠️ Cannot reach metrics endpoint\n"
        echo -n "$issues"
        return
    fi

    # Ingestion lag
    local last_ingested
    last_ingested=$(echo "$metrics" \
        | grep 'splice_store_last_ingested_record_time_ms' \
        | grep -v '#' \
        | awk '{print $2}' | sort -n | tail -1)

    if [ -n "$last_ingested" ] && [ "$last_ingested" != "0" ]; then
        local now_ms lag_s
        now_ms=$(python3 -c "import time; print(int(time.time() * 1000))")
        lag_s=$(python3 -c "print(int(max(0, (int($now_ms) - int(float($last_ingested))) // 1000)))")

        if [ "$lag_s" -gt "$SYNC_LAG_CRIT" ]; then
            issues="${issues}🔴 Sync lag: ${lag_s}s (critical, >${SYNC_LAG_CRIT}s)\n"
        elif [ "$lag_s" -gt "$SYNC_LAG_WARN" ]; then
            issues="${issues}🟡 Sync lag: ${lag_s}s (warning, >${SYNC_LAG_WARN}s)\n"
        fi
    fi

    # Retry failures
    local retry_failures
    retry_failures=$(echo "$metrics" \
        | grep '^splice_retries_failures' \
        | awk '{sum+=$2} END {print int(sum)}')

    if [ -n "$retry_failures" ] && [ "$retry_failures" -gt "$RETRY_FAIL_THRESH" ]; then
        issues="${issues}🟡 Retry failures: ${retry_failures} (>${RETRY_FAIL_THRESH})\n"
    fi

    echo -n "$issues"
}

# ============================================================
# Disk space check
# ============================================================
check_disk() {
    local issues=""
    local avail_kb avail_gb
    avail_kb=$(df / | awk 'NR==2 {print $4}')
    avail_gb=$((avail_kb / 1024 / 1024))

    if [ "$avail_gb" -lt "$DISK_WARN_GB" ]; then
        issues="${issues}🔴 Disk free: ${avail_gb}GB (critical, <${DISK_WARN_GB}GB)\n"
    fi

    echo -n "$issues"
}

# ============================================================
# State machine — alert once, recover once, no spam
# ============================================================
run_state_machine() {
    local alert_text="$1"
    local is_critical=0
    [ -n "$alert_text" ] && is_critical=1

    local prev_state="0"
    [ -f "$STATE_FILE" ] && prev_state=$(cat "$STATE_FILE")

    local prev_msgid=""
    [ -f "$MSGID_FILE" ] && prev_msgid=$(cat "$MSGID_FILE")

    if [ "$is_critical" -eq 1 ] && [ "$prev_state" != "1" ]; then
        # New failure — send + pin
        local message
        message="🚨 <b>${NODE_NAME}</b>
Host: $(hostname)

${alert_text}
Time: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"

        local msg_id
        msg_id=$(send_telegram "$message")
        if [ -n "$msg_id" ]; then
            pin_message "$msg_id"
            echo "$msg_id" > "$MSGID_FILE"
        fi
        echo "1" > "$STATE_FILE"
        log "ALERT sent (msg_id: ${msg_id:-n/a})"

    elif [ "$is_critical" -eq 0 ] && [ "$prev_state" = "1" ]; then
        # Recovery — unpin + send resolved
        [ -n "$prev_msgid" ] && unpin_message "$prev_msgid"
        send_telegram "✅ <b>${NODE_NAME}</b> — RESOLVED
Host: $(hostname)
Time: $(date -u '+%Y-%m-%d %H:%M:%S UTC')" > /dev/null

        echo "0" > "$STATE_FILE"
        rm -f "$MSGID_FILE"
        log "RECOVERY sent, alert unpinned"

    elif [ "$is_critical" -eq 1 ]; then
        # Still failing — no repeat telegram, just log
        log "Still failing (no repeat alert):"
        echo -e "$alert_text" | sed 's/^/  /'

    else
        log "All checks passed"
    fi
}

# ============================================================
# Main
# ============================================================
main() {
    log "Running health check — $NODE_NAME"

    local all_issues=""

    log "Checking containers..."
    container_issues=$(check_containers)
    all_issues="${all_issues}${container_issues}"

    log "Checking sync lag + retry failures..."
    metrics_issues=$(check_sync_lag)
    all_issues="${all_issues}${metrics_issues}"

    log "Checking disk space..."
    disk_issues=$(check_disk)
    all_issues="${all_issues}${disk_issues}"

    run_state_machine "$all_issues"
}

main "$@"
