#!/bin/bash
set -euo pipefail

# ============================================================
# Canton Validator Toolkit — auto_upgrade.sh
# Universal upgrader for mainnet / testnet / devnet
# Reads all config from ~/.canton/toolkit.conf
# ============================================================

CANTON_DIR="$HOME/.canton"
TOOLKIT_CONF="$CANTON_DIR/toolkit.conf"
LOCKFILE="/tmp/canton_upgrade.lock"
LOG_DIR="$CANTON_DIR/logs"

log()     { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
success() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✓ $1"; }
warn()    { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠ $1"; }
error()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✗ $1" >&2; }
die()     { error "$1"; send_telegram "❌ <b>${NODE_NAME:-Canton}</b>%0A%0A$1%0AHost: $(hostname)"; cleanup; exit 1; }

# ============================================================
# Load config
# ============================================================
if [ ! -f "$TOOLKIT_CONF" ]; then
    echo "toolkit.conf not found: $TOOLKIT_CONF — run setup.sh first" >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$TOOLKIT_CONF"

NETWORK="${NETWORK:-mainnet}"
PARTY_HINT="${PARTY_HINT:-}"
MIGRATION_ID="${MIGRATION_ID:-1}"
SV_URL="${SV_URL:-}"
SCAN_URL="${SCAN_URL:-}"
NODE_NAME="${NODE_NAME:-Canton-Validator}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
WAIT_HOURS="${WAIT_HOURS:-12}"
AUTO_UPGRADE="${AUTO_UPGRADE:-false}"
TOOLKIT_DIR="${TOOLKIT_DIR:-$HOME/canton-validator-toolkit}"

# AUTO_UPGRADE guard — default is false, must be explicitly enabled
if [ "$AUTO_UPGRADE" != "true" ]; then
    log "Auto-upgrade is disabled (AUTO_UPGRADE=false in toolkit.conf)"
    log "To upgrade manually: $TOOLKIT_DIR/scripts/setup.sh → option 2"
    log "To enable auto-upgrade: set AUTO_UPGRADE=true in ~/.canton/toolkit.conf"
    exit 0
fi

mkdir -p "$LOG_DIR"

# ============================================================
# Lockfile
# ============================================================
cleanup() {
    rm -f "$LOCKFILE"
}
trap cleanup EXIT

if [ -f "$LOCKFILE" ]; then
    log "Another upgrade in progress (pid: $(cat "$LOCKFILE")), exiting"
    exit 0
fi
echo $$ > "$LOCKFILE"

# ============================================================
# Telegram
# ============================================================
send_telegram() {
    [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ] && return 0
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TELEGRAM_CHAT_ID}" \
        -d parse_mode="HTML" \
        -d text="$1" > /dev/null 2>&1 || true
}

# ============================================================
# Get validator container name dynamically
# ============================================================
get_validator_container() {
    docker ps --format '{{.Names}}' | grep -E 'validator-1$' | grep -v postgres | head -1
}

# ============================================================
# Get current running version from container image tag
# ============================================================
get_our_version() {
    local c
    c=$(get_validator_container)
    [ -z "$c" ] && echo "" && return
    docker inspect "$c" --format '{{.Config.Image}}' 2>/dev/null \
        | grep -oP ':\K[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

# ============================================================
# Get network version
# mainnet  → scan API
# testnet  → lighthouse API (fallback: scan API)
# devnet   → lighthouse API (fallback: scan API)
# ============================================================
get_network_version() {
    local version=""

    case "$NETWORK" in
        mainnet)
            # Scan API may return 403 depending on server IP — fallback to GitHub
            version=$(curl -sf --max-time 10 \
                "https://scan.sv-2.global.canton.network.digitalasset.com/api/scan/version" \
                2>/dev/null | grep -oP '"version"\s*:\s*"\K[0-9.]+' | head -1)
            if [ -z "$version" ]; then
                version=$(curl -sf --max-time 10 \
                    "https://api.github.com/repos/digital-asset/decentralized-canton-sync/releases/latest" \
                    2>/dev/null | grep -oP '"tag_name"\s*:\s*"v\K[0-9.]+' | head -1)
                [ -n "$version" ] && warn "Scan API unavailable, using GitHub latest: $version"
            fi
            ;;
        testnet)
            version=$(curl -sf --max-time 10 \
                "https://lighthouse.testnet.cantonloop.com/api/stats" \
                2>/dev/null | grep -oP '"version"\s*:\s*"\K[0-9.]+' | head -1)
            if [ -z "$version" ]; then
                version=$(curl -sf --max-time 10 \
                    "https://scan.sv-2.test.global.canton.network.digitalasset.com/api/scan/version" \
                    2>/dev/null | grep -oP '"version"\s*:\s*"\K[0-9.]+' | head -1)
                [ -n "$version" ] && warn "Lighthouse unavailable, used scan API fallback"
            fi
            ;;
        devnet)
            version=$(curl -sf --max-time 10 \
                "https://lighthouse.devnet.cantonloop.com/api/stats" \
                2>/dev/null | grep -oP '"version"\s*:\s*"\K[0-9.]+' | head -1)
            if [ -z "$version" ]; then
                version=$(curl -sf --max-time 10 \
                    "https://scan.sv-2.dev.global.canton.network.digitalasset.com/api/scan/version" \
                    2>/dev/null | grep -oP '"version"\s*:\s*"\K[0-9.]+' | head -1)
                [ -n "$version" ] && warn "Lighthouse unavailable, used scan API fallback"
            fi
            ;;
    esac

    echo "$version"
}

# ============================================================
# Compare semver: returns 0 if $1 >= $2
# ============================================================
version_gte() {
    [ "$(printf '%s\n%s' "$1" "$2" | sort -V | tail -1)" = "$1" ]
}

# ============================================================
# Check release age on GitHub
# ============================================================
check_release_age() {
    local version="$1"
    local release_date age_hours

    release_date=$(curl -sf --max-time 10 \
        "https://api.github.com/repos/digital-asset/decentralized-canton-sync/releases/tags/v${version}" \
        2>/dev/null | grep -oP '"published_at"\s*:\s*"\K[^"]+' | head -1)

    if [ -z "$release_date" ]; then
        warn "Cannot get release date for v${version}, proceeding anyway"
        return 0
    fi

    local release_ts now_ts
    release_ts=$(date -d "$release_date" +%s 2>/dev/null || echo 0)
    now_ts=$(date +%s)
    age_hours=$(( (now_ts - release_ts) / 3600 ))

    log "Release age: ${age_hours}h (min required: ${WAIT_HOURS}h)"

    if [ "$age_hours" -lt "$WAIT_HOURS" ]; then
        log "Release too fresh (${age_hours}h < ${WAIT_HOURS}h), skipping"
        return 1
    fi

    return 0
}

# ============================================================
# Download bundle
# ============================================================
download_bundle() {
    local version="$1"
    local target_dir="$CANTON_DIR/$version"

    if [ -d "$target_dir/splice-node" ]; then
        success "Bundle $version already downloaded"
        return 0
    fi

    mkdir -p "$target_dir"
    cd "$target_dir"

    local bundle_url="https://github.com/digital-asset/decentralized-canton-sync/releases/download/v${version}/${version}_splice-node.tar.gz"
    log "Downloading v${version}..."

    if ! curl -fL --progress-bar "$bundle_url" -o "${version}_splice-node.tar.gz"; then
        rm -f "${version}_splice-node.tar.gz"
        die "Download failed: $bundle_url"
    fi

    log "Extracting..."
    tar xzf "${version}_splice-node.tar.gz"
    rm -f "${version}_splice-node.tar.gz"
    success "Bundle extracted: $target_dir"
}

# ============================================================
# Copy config from previous version to new version
# .env, nginx.conf, nginx/ (incl. .htpasswd)
# ============================================================
migrate_config() {
    local old_version="$1"
    local new_version="$2"

    local old_dir="$CANTON_DIR/$old_version/splice-node/docker-compose/validator"
    local new_dir="$CANTON_DIR/$new_version/splice-node/docker-compose/validator"

    if [ ! -d "$old_dir" ]; then
        die "Previous version dir not found: $old_dir"
    fi

    log "Migrating config from $old_version → $new_version..."

    # .env
    cp "$old_dir/.env" "$new_dir/.env"

    # nginx.conf
    if [ -f "$old_dir/nginx.conf" ]; then
        cp "$old_dir/nginx.conf" "$new_dir/nginx.conf"
        success "nginx.conf copied"
    else
        warn "nginx.conf not found in old version — will use toolkit template"
        if [ -f "$TOOLKIT_DIR/scripts/setup.sh" ]; then
            # Extract nginx template via setup helper (sourced write_nginx_conf)
            warn "Run setup.sh to regenerate nginx.conf if wallet is broken"
        fi
    fi

    # nginx/ dir (incl. .htpasswd)
    if [ -d "$old_dir/nginx" ]; then
        cp -r "$old_dir/nginx" "$new_dir/nginx"
        success "nginx/ dir copied (incl. .htpasswd)"
    fi

    success "Config migrated"
}

# ============================================================
# Patch .env for new version
# ============================================================
patch_env() {
    local version="$1"
    local env_file="$CANTON_DIR/$version/splice-node/docker-compose/validator/.env"

    log "Patching .env for $version..."

    # Update IMAGE_TAG
    if grep -q "^IMAGE_TAG=" "$env_file"; then
        sed -i "s|^IMAGE_TAG=.*|IMAGE_TAG=${version}|" "$env_file"
    else
        echo "IMAGE_TAG=${version}" >> "$env_file"
    fi

    # Ensure AUTH_URL is not empty
    if grep -q '^AUTH_URL=""' "$env_file" || grep -q '^AUTH_URL=$' "$env_file"; then
        sed -i 's|^AUTH_URL=.*|AUTH_URL=https://unsafe.auth|' "$env_file"
    fi
    grep -q "^AUTH_URL=" "$env_file" || echo "AUTH_URL=https://unsafe.auth" >> "$env_file"

    # Ensure COMPOSE_FILE includes disable-auth overlay
    if ! grep -q "^COMPOSE_FILE=" "$env_file"; then
        echo "COMPOSE_FILE=compose.yaml:compose-disable-auth.yaml" >> "$env_file"
    fi

    # Ensure all SPLICE_APP_UI_* vars present (ZodError prevention)
    if ! grep -q "^SPLICE_APP_UI_NETWORK_NAME=" "$env_file"; then
        printf '\n# UI Branding\nSPLICE_APP_UI_NETWORK_NAME=Canton Network\nSPLICE_APP_UI_NETWORK_FAVICON_URL=https://www.canton.network/hubfs/cn-favicon-05%%201-1.png\nSPLICE_APP_UI_AMULET_NAME=Canton Coin\nSPLICE_APP_UI_AMULET_NAME_ACRONYM=CC\nSPLICE_APP_UI_NAME_SERVICE_NAME=Canton Name Service\nSPLICE_APP_UI_NAME_SERVICE_NAME_ACRONYM=CNS\n' >> "$env_file"
        success "SPLICE_APP_UI_* vars added"
    fi

    success ".env patched"
}

# ============================================================
# Patch compose.yaml port (80 → 8888, localhost-only bind)
# ============================================================
patch_compose() {
    local version="$1"
    local compose_file="$CANTON_DIR/$version/splice-node/docker-compose/validator/compose.yaml"

    [ ! -f "$compose_file" ] && warn "compose.yaml not found, skipping port patch" && return

    sed -i 's|"${HOST_BIND_IP:-0\.0\.0\.0}:80:80"|"${HOST_BIND_IP:-127.0.0.1}:8888:80"|g' "$compose_file"
    sed -i 's|"${HOST_BIND_IP:-127\.0\.0\.1}:80:80"|"${HOST_BIND_IP:-127.0.0.1}:8888:80"|g' "$compose_file"
    sed -i 's|"0\.0\.0\.0:80:80"|"127.0.0.1:8888:80"|g' "$compose_file"
    sed -i 's|"127\.0\.0\.1:80:80"|"127.0.0.1:8888:80"|g' "$compose_file"
    success "compose.yaml patched (port 8888)"
}

# ============================================================
# Pre-pull images while old node is still running
# ============================================================
prepull_images() {
    local version="$1"
    local validator_dir="$CANTON_DIR/$version/splice-node/docker-compose/validator"

    log "Pre-pulling images for v${version} (old node still running)..."
    cd "$validator_dir"
    export IMAGE_TAG="$version"

    if ! docker compose --env-file .env pull 2>&1 | tail -5; then
        die "Image pull failed for v${version}"
    fi
    success "Images pulled"
}

# ============================================================
# Stop old version
# ============================================================
stop_old() {
    local version="$1"
    local validator_dir="$CANTON_DIR/$version/splice-node/docker-compose/validator"

    if [ ! -d "$validator_dir" ]; then
        warn "Old validator dir not found: $validator_dir"
        return
    fi

    log "Stopping v${version}..."
    cd "$validator_dir"
    export IMAGE_TAG="$version"
    ./stop.sh 2>/dev/null || docker compose down 2>/dev/null || true
    success "v${version} stopped"
}

# ============================================================
# Start new version
# ============================================================
start_new() {
    local version="$1"
    local validator_dir="$CANTON_DIR/$version/splice-node/docker-compose/validator"

    log "Starting v${version}..."
    cd "$validator_dir"
    export IMAGE_TAG="$version"

    local onboarding_secret="${ONBOARDING_SECRET:-}"
    local start_args="-s $SV_URL -c $SCAN_URL -p $PARTY_HINT -m $MIGRATION_ID -o \"$onboarding_secret\" -w"

    if ! eval ./start.sh $start_args; then
        return 1
    fi

    success "v${version} started"
    return 0
}

# ============================================================
# Check health after start
# ============================================================
wait_healthy() {
    local version="$1"
    log "Waiting for validator to become healthy (up to 60s)..."

    local attempts=0
    while [ $attempts -lt 6 ]; do
        sleep 10
        attempts=$((attempts + 1))
        local status
        local vc
        vc=$(get_validator_container)
        status=$(docker inspect --format='{{.State.Health.Status}}' \
            "${vc:-splice-validator-validator-1}" 2>/dev/null || echo "not_found")
        log "[$attempts/6] health: $status"
        [ "$status" = "healthy" ] && return 0
    done

    return 1
}

# ============================================================
# Rollback to old version
# ============================================================
rollback() {
    local old_version="$1"

    warn "Rolling back to $old_version..."
    send_telegram "⚠️ <b>${NODE_NAME}</b>%0A%0ARolling back to ${old_version}..."

    if start_new "$old_version"; then
        send_telegram "🔙 <b>${NODE_NAME}</b>%0A%0ARolled back to ${old_version} successfully"
        warn "Rollback complete"
    else
        send_telegram "❌ <b>${NODE_NAME}</b>%0A%0ARollback to ${old_version} FAILED — manual intervention required!"
        error "Rollback failed — check manually"
    fi
}

# ============================================================
# Update symlink and toolkit.conf version
# ============================================================
update_current() {
    local version="$1"

    ln -sfn "$CANTON_DIR/$version" "$CANTON_DIR/current"
    success "Symlink updated: ~/.canton/current → $version"

    # Update VERSION in toolkit.conf
    if grep -q "^VERSION=" "$TOOLKIT_CONF"; then
        sed -i "s|^VERSION=.*|VERSION=${version}|" "$TOOLKIT_CONF"
    else
        echo "VERSION=${version}" >> "$TOOLKIT_CONF"
    fi
}

# ============================================================
# Main
# ============================================================
main() {
    log "=== Auto-upgrade started — network: $NETWORK ==="

    # Get versions
    OUR_VERSION=$(get_our_version)
    if [ -z "$OUR_VERSION" ]; then
        die "Cannot detect running version — is the validator running?"
    fi
    log "Current version: $OUR_VERSION"

    NETWORK_VERSION=$(get_network_version)
    if [ -z "$NETWORK_VERSION" ]; then
        die "Cannot detect network version — check connectivity"
    fi
    log "Network version: $NETWORK_VERSION"

    # Already up to date
    if [ "$OUR_VERSION" = "$NETWORK_VERSION" ]; then
        success "Already on latest version: $OUR_VERSION"
        exit 0
    fi

    # Anti-downgrade
    if version_gte "$OUR_VERSION" "$NETWORK_VERSION"; then
        log "Our version ($OUR_VERSION) >= network ($NETWORK_VERSION), skipping"
        exit 0
    fi

    # Major version check
    local our_major net_major
    our_major=$(echo "$OUR_VERSION" | cut -d. -f1-2)
    net_major=$(echo "$NETWORK_VERSION" | cut -d. -f1-2)

    if [ "$our_major" != "$net_major" ]; then
        warn "Major version change detected: $OUR_VERSION → $NETWORK_VERSION"
        send_telegram "⚠️ <b>${NODE_NAME}</b>%0A%0AMAJOR update available: ${OUR_VERSION} → ${NETWORK_VERSION}%0A%0AManual upgrade required!%0AHost: $(hostname)"
        exit 0
    fi

    # Release age check
    if ! check_release_age "$NETWORK_VERSION"; then
        exit 0
    fi

    log "Upgrade needed: $OUR_VERSION → $NETWORK_VERSION"
    send_telegram "🔄 <b>${NODE_NAME}</b>%0A%0AStarting auto-upgrade: ${OUR_VERSION} → ${NETWORK_VERSION}%0AHost: $(hostname)"

    # Backup first
    if [ -f "$TOOLKIT_DIR/scripts/backup.sh" ]; then
        log "Running backup before upgrade..."
        if ! bash "$TOOLKIT_DIR/scripts/backup.sh"; then
            die "Backup failed — upgrade aborted"
        fi
        success "Backup complete"
    else
        warn "backup.sh not found, skipping pre-upgrade backup"
    fi

    # Download new bundle
    download_bundle "$NETWORK_VERSION"

    # Migrate config
    migrate_config "$OUR_VERSION" "$NETWORK_VERSION"

    # Patch .env and compose.yaml
    patch_env "$NETWORK_VERSION"
    patch_compose "$NETWORK_VERSION"

    # Pre-pull images while old node is still up
    prepull_images "$NETWORK_VERSION"

    # Stop old
    stop_old "$OUR_VERSION"

    # Start new
    if ! start_new "$NETWORK_VERSION"; then
        error "Start failed for v${NETWORK_VERSION}"
        rollback "$OUR_VERSION"
        exit 1
    fi

    # Verify health
    if wait_healthy "$NETWORK_VERSION"; then
        update_current "$NETWORK_VERSION"
        success "Upgrade complete: $OUR_VERSION → $NETWORK_VERSION"
        send_telegram "✅ <b>${NODE_NAME}</b>%0A%0AUpgrade SUCCESS: ${OUR_VERSION} → ${NETWORK_VERSION}%0AValidator: healthy%0AHost: $(hostname)"
    else
        error "Validator unhealthy after upgrade"
        send_telegram "❌ <b>${NODE_NAME}</b>%0A%0AValidator unhealthy after upgrade to ${NETWORK_VERSION}%0ARolling back..."
        stop_old "$NETWORK_VERSION"
        rollback "$OUR_VERSION"
        exit 1
    fi

    log "=== Auto-upgrade finished ==="
}

main "$@"
