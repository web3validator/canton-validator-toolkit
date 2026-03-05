#!/bin/bash
set -euo pipefail

# ============================================================
# Canton Validator Toolkit — backup.sh
# Backs up validator + participant PostgreSQL DBs
# Supports: rsync (SSH) | r2 (Cloudflare R2 via rclone)
# ============================================================

CANTON_DIR="$HOME/.canton"
TOOLKIT_CONF="$CANTON_DIR/toolkit.conf"
BACKUP_DIR="$HOME/.canton/backups"
DATE=$(date -u +"%Y%m%d_%H%M%S")

log()     { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
success() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✓ $1"; }
warn()    { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠ $1"; }
error()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✗ $1" >&2; }
die()     { error "$1"; _backup_alert_failure "$1"; exit 1; }

# ============================================================
# Load config
# ============================================================
if [ ! -f "$TOOLKIT_CONF" ]; then
    die "toolkit.conf not found: $TOOLKIT_CONF — run setup.sh first"
fi
# shellcheck source=/dev/null
source "$TOOLKIT_CONF"

NETWORK="${NETWORK:-mainnet}"
BACKUP_TYPE="${BACKUP_TYPE:-skip}"
REMOTE_HOST="${REMOTE_HOST:-}"
REMOTE_PATH="${REMOTE_PATH:-~/canton-backups/$NETWORK}"
R2_BUCKET="${R2_BUCKET:-}"
R2_ACCOUNT_ID="${R2_ACCOUNT_ID:-}"
R2_ACCESS_KEY="${R2_ACCESS_KEY:-}"
R2_SECRET_KEY="${R2_SECRET_KEY:-}"
RETENTION_DAYS="${RETENTION_DAYS:-1}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
PAGERDUTY_ROUTING_KEY="${PAGERDUTY_ROUTING_KEY:-}"
NODE_NAME="${NODE_NAME:-Canton-Validator}"

BACKUP_STATE_DIR="$CANTON_DIR/health"
BACKUP_STATE_FILE="$BACKUP_STATE_DIR/backup_state"
mkdir -p "$BACKUP_STATE_DIR"

# ============================================================
# Alert channels
# ============================================================
_tg() {
    [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ] && return 0
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TELEGRAM_CHAT_ID}" \
        -d parse_mode="HTML" \
        -d text="$1" > /dev/null 2>&1 || true
}
_discord() {
    [ -z "$DISCORD_WEBHOOK_URL" ] && return 0
    local text; text=$(echo "$1" | sed 's/<b>//g; s/<\/b>//g; s/<[^>]*>//g')
    curl -s -X POST "$DISCORD_WEBHOOK_URL" -H "Content-Type: application/json" \
        -d "{\"content\": $(python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))" <<< "$text")}" \
        > /dev/null 2>&1 || true
}
_slack() {
    [ -z "$SLACK_WEBHOOK_URL" ] && return 0
    local text; text=$(echo "$1" | sed 's/<b>//g; s/<\/b>//g; s/<[^>]*>//g')
    curl -s -X POST "$SLACK_WEBHOOK_URL" -H "Content-Type: application/json" \
        -d "{\"text\": $(python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))" <<< "$text")}" \
        > /dev/null 2>&1 || true
}
_pagerduty() {
    [ -z "$PAGERDUTY_ROUTING_KEY" ] && return 0
    local action="$2"
    local summary; summary=$(echo "$1" | sed 's/<[^>]*>//g' | head -c 1024)
    curl -s -X POST "https://events.pagerduty.com/v2/enqueue" \
        -H "Content-Type: application/json" \
        -d "{\"routing_key\":\"${PAGERDUTY_ROUTING_KEY}\",\"event_action\":\"${action}\",\"dedup_key\":\"canton-backup-$(hostname)\",\"payload\":{\"summary\":$(python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))" <<< "$summary"),\"source\":\"$(hostname)\",\"severity\":\"critical\"}}" \
        > /dev/null 2>&1 || true
}

send_alert() {
    local text="$1" action="${2:-trigger}"
    _tg "$text"; _discord "$text"; _slack "$text"; _pagerduty "$text" "$action"
}

# ============================================================
# Backup state machine — alert on failure, recovery on fix, silent on success
# ============================================================
_backup_alert_failure() {
    local reason="$1"
    local prev_state="0"
    [ -f "$BACKUP_STATE_FILE" ] && prev_state=$(cat "$BACKUP_STATE_FILE")

    local msg="❌ <b>${NODE_NAME}</b> — Backup FAILED

${reason}
Host: $(hostname)
Time: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"

    if [ "$prev_state" != "1" ]; then
        send_alert "$msg" "trigger"
        log "ALERT sent — backup failure"
    else
        log "Still failing (no repeat alert)"
    fi
    echo "1" > "$BACKUP_STATE_FILE"
}

_backup_alert_success() {
    local prev_state="0"
    [ -f "$BACKUP_STATE_FILE" ] && prev_state=$(cat "$BACKUP_STATE_FILE")

    if [ "$prev_state" = "1" ]; then
        local msg="✅ <b>${NODE_NAME}</b> — Backup RECOVERED
Type: ${BACKUP_TYPE}
Host: $(hostname)
Time: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
        send_alert "$msg" "resolve"
        log "RECOVERY sent"
    else
        log "Backup OK (no alert — was already healthy)"
    fi
    echo "0" > "$BACKUP_STATE_FILE"
}

# ============================================================
# Detect postgres container
# ============================================================
get_postgres_container() {
    local container
    container=$(docker ps --format '{{.Names}}' 2>/dev/null \
        | grep -E 'postgres-splice' | head -1)
    echo "$container"
}

# ============================================================
# Dump databases
# ============================================================
dump_databases() {
    local pg_container
    pg_container=$(get_postgres_container)

    if [ -z "$pg_container" ]; then
        die "PostgreSQL container not found. Is the validator running?"
    fi

    log "PostgreSQL container: $pg_container"
    mkdir -p "$BACKUP_DIR"

    # Validator DB
    log "Dumping validator DB..."
    if ! docker exec "$pg_container" pg_dump -U cnadmin validator \
        | gzip > "$BACKUP_DIR/validator_${DATE}.sql.gz"; then
        die "pg_dump failed for validator DB"
    fi
    success "validator_${DATE}.sql.gz — $(du -sh "$BACKUP_DIR/validator_${DATE}.sql.gz" | cut -f1)"

    # Participant DB — detect name from running container env
    local participant_db
    local PARTICIPANT_CONTAINER=$(docker ps --format "{{.Names}}" | grep "participant-1" | head -1)
    participant_db=$(docker exec "$PARTICIPANT_CONTAINER" \
        bash -c 'echo $CANTON_PARTICIPANT_POSTGRES_DB' 2>/dev/null || echo "")

    if [ -z "$participant_db" ]; then
        warn "Could not detect participant DB name, trying 'participant_0'..."
        participant_db="participant_0"
    fi

    log "Dumping participant DB ($participant_db)..."
    if ! docker exec "$pg_container" pg_dump -U cnadmin "$participant_db" \
        | gzip > "$BACKUP_DIR/${participant_db}_${DATE}.sql.gz"; then
        warn "pg_dump failed for participant DB — continuing without it"
    else
        success "${participant_db}_${DATE}.sql.gz — $(du -sh "$BACKUP_DIR/${participant_db}_${DATE}.sql.gz" | cut -f1)"
    fi

    VALIDATOR_DUMP="$BACKUP_DIR/validator_${DATE}.sql.gz"
    PARTICIPANT_DUMP="$BACKUP_DIR/${participant_db}_${DATE}.sql.gz"
}

# ============================================================
# rsync upload
# ============================================================
upload_rsync() {
    if [ -z "$REMOTE_HOST" ]; then
        die "REMOTE_HOST not set in toolkit.conf"
    fi

    # Expand ~ to absolute path on remote (in case old config stored ~/...)
    local remote_user
    remote_user=$(echo "$REMOTE_HOST" | cut -d@ -f1)
    REMOTE_PATH="${REMOTE_PATH/#\~//home/${remote_user}}"

    log "Syncing to $REMOTE_HOST:$REMOTE_PATH ..."

    # Ensure remote dir exists
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$REMOTE_HOST" \
        "mkdir -p $REMOTE_PATH" 2>/dev/null \
        || die "Cannot connect to $REMOTE_HOST — check SSH key"

    rsync -az --no-perms \
        "$VALIDATOR_DUMP" \
        $([ -f "$PARTICIPANT_DUMP" ] && echo "$PARTICIPANT_DUMP" || echo "") \
        "${REMOTE_HOST}:${REMOTE_PATH}/" \
        || die "rsync failed"

    # Cleanup old remote backups
    ssh -o BatchMode=yes "$REMOTE_HOST" \
        "find $REMOTE_PATH -name '*.sql.gz' -mtime +${RETENTION_DAYS} -delete 2>/dev/null; echo 'remote cleanup done'" \
        || warn "Remote cleanup failed (non-fatal)"

    success "rsync upload complete"
}

# ============================================================
# rclone / R2 upload
# ============================================================
setup_rclone_r2() {
    if ! command -v rclone &>/dev/null; then
        log "Installing rclone..."
        curl -fsSL https://rclone.org/install.sh | sudo bash -s -- --no-unpack 2>/dev/null \
            || sudo apt-get install -y rclone 2>/dev/null \
            || die "Cannot install rclone"
    fi

    # Write rclone config for R2
    local rclone_conf="$HOME/.config/rclone/rclone.conf"
    mkdir -p "$(dirname "$rclone_conf")"

    # Remove old canton-r2 section if exists
    if [ -f "$rclone_conf" ]; then
        python3 - "$rclone_conf" <<'PYEOF'
import sys, re
content = open(sys.argv[1]).read()
content = re.sub(r'\[canton-r2\][^\[]*', '', content, flags=re.DOTALL)
open(sys.argv[1], 'w').write(content.strip() + '\n')
PYEOF
    fi

    printf '[canton-r2]\ntype = s3\nprovider = Cloudflare\naccess_key_id = %s\nsecret_access_key = %s\nendpoint = https://%s.r2.cloudflarestorage.com\nacl = private\n' \
        "$R2_ACCESS_KEY" "$R2_SECRET_KEY" "$R2_ACCOUNT_ID" >> "$rclone_conf"
}

upload_r2() {
    if [ -z "$R2_BUCKET" ] || [ -z "$R2_ACCOUNT_ID" ] || [ -z "$R2_ACCESS_KEY" ] || [ -z "$R2_SECRET_KEY" ]; then
        die "R2 credentials incomplete in toolkit.conf"
    fi

    setup_rclone_r2

    local remote_path="canton-r2:${R2_BUCKET}/${NETWORK}"
    log "Uploading to R2: $remote_path ..."

    rclone copy "$VALIDATOR_DUMP" "$remote_path/" \
        || die "rclone upload failed for validator dump"

    if [ -f "$PARTICIPANT_DUMP" ]; then
        rclone copy "$PARTICIPANT_DUMP" "$remote_path/" \
            || warn "rclone upload failed for participant dump (non-fatal)"
    fi

    # Cleanup old R2 backups (files older than RETENTION_DAYS)
    log "Cleaning up R2 backups older than ${RETENTION_DAYS} days..."
    rclone delete "$remote_path/" \
        --min-age "${RETENTION_DAYS}d" \
        --include '*.sql.gz' 2>/dev/null || warn "R2 cleanup failed (non-fatal)"

    success "R2 upload complete"
}

# ============================================================
# Cleanup local dumps
# ============================================================
cleanup_local() {
    log "Cleaning up local backups older than ${RETENTION_DAYS} days..."
    find "$BACKUP_DIR" -name '*.sql.gz' -mtime "+${RETENTION_DAYS}" -delete 2>/dev/null || true
    success "Local cleanup done"

    log "Current local backups:"
    ls -lh "$BACKUP_DIR"/*.sql.gz 2>/dev/null || echo "  (none)"
}

# ============================================================
# Main
# ============================================================
main() {
    log "Starting backup — network: $NETWORK, type: $BACKUP_TYPE"

    if [ "$BACKUP_TYPE" = "skip" ]; then
        log "Backup type is 'skip', exiting"
        exit 0
    fi

    dump_databases

    case "$BACKUP_TYPE" in
        rsync) upload_rsync ;;
        r2)    upload_r2 ;;
        *)     die "Unknown BACKUP_TYPE: $BACKUP_TYPE (valid: rsync | r2 | skip)" ;;
    esac

    cleanup_local

    success "Backup completed successfully"
    _backup_alert_success
}

main "$@"
