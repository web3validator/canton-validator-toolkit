#!/bin/bash
set -euo pipefail

# ============================================================
# Canton Validator Toolkit — setup.sh
# Modes: install | update | status
# ============================================================

TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANTON_DIR="$HOME/.canton"
LOG_DIR="$CANTON_DIR/logs"
TOOLKIT_CONF="$CANTON_DIR/toolkit.conf"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log()     { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $1"; }
success() { echo -e "${GREEN}[$(date '+%H:%M:%S')] ✓${NC} $1"; }
warn()    { echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠${NC} $1"; }
error()   { echo -e "${RED}[$(date '+%H:%M:%S')] ✗${NC} $1"; }
die()     { error "$1"; exit 1; }

# ============================================================
# Dependency check
# ============================================================
check_deps() {
    local missing=()
    for cmd in docker curl jq python3 openssl rsync; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    docker compose version &>/dev/null || missing+=("docker-compose-plugin")

    if [ ${#missing[@]} -gt 0 ]; then
        die "Missing dependencies: ${missing[*]}\nInstall with: sudo apt-get install -y ${missing[*]}"
    fi
    success "All dependencies satisfied"
}

# ============================================================
# Helpers
# ============================================================
prompt() {
    local var_name="$1"
    local prompt_text="$2"
    local default="${3:-}"
    local value

    if [ -n "$default" ]; then
        read -rp "$(echo -e "${BOLD}${prompt_text}${NC} [${default}]: ")" value
        value="${value:-$default}"
    else
        read -rp "$(echo -e "${BOLD}${prompt_text}${NC}: ")" value
    fi
    printf -v "$var_name" '%s' "$value"
}

prompt_secret() {
    local var_name="$1"
    local prompt_text="$2"
    local value
    read -rsp "$(echo -e "${BOLD}${prompt_text}${NC}: ")" value
    echo
    printf -v "$var_name" '%s' "$value"
}

get_latest_version() {
    curl -sf --max-time 10 \
        "https://api.github.com/repos/digital-asset/decentralized-canton-sync/releases/latest" \
        | grep -oP '"tag_name"\s*:\s*"v\K[0-9.]+' | head -1
}

# SV endpoint lists per network — tried in order, first accessible wins
SV_LIST_MAINNET=(
    "https://scan.sv-1.global.canton.network.digitalasset.com"
    "https://scan.sv-2.global.canton.network.digitalasset.com"
    "https://scan.sv-1.global.canton.network.sync.global"
    "https://scan.sv-1.global.canton.network.cumberland.io"
    "https://scan.sv-2.global.canton.network.cumberland.io"
    "https://scan.sv-1.global.canton.network.c7.digital"
    "https://scan.sv-1.global.canton.network.fivenorth.io"
    "https://scan.sv-1.global.canton.network.lcv.mpch.io"
    "https://scan.sv-1.global.canton.network.mpch.io"
    "https://scan.sv-1.global.canton.network.orb1lp.mpch.io"
    "https://scan.sv-1.global.canton.network.proofgroup.xyz"
    "https://scan.sv.global.canton.network.sv-nodeops.com"
    "https://scan.sv-1.global.canton.network.tradeweb.com"
)

SV_LIST_TESTNET=(
    "https://scan.sv-1.test.global.canton.network.digitalasset.com"
    "https://scan.sv-2.test.global.canton.network.digitalasset.com"
    "https://scan.sv.test.global.canton.network.digitalasset.com"
    "https://scan.sv-1.test.global.canton.network.sync.global"
    "https://scan.sv-1.test.global.canton.network.cumberland.io"
    "https://scan.sv-2.test.global.canton.network.cumberland.io"
    "https://scan.sv-1.test.global.canton.network.c7.digital"
    "https://scan.sv-1.test.global.canton.network.fivenorth.io"
    "https://scan.sv-1.test.global.canton.network.lcv.mpch.io"
    "https://scan.sv-1.test.global.canton.network.mpch.io"
    "https://scan.sv-1.test.global.canton.network.orb1lp.mpch.io"
    "https://scan.sv-1.test.global.canton.network.proofgroup.xyz"
    "https://scan.sv.test.global.canton.network.sv-nodeops.com"
    "https://scan.sv-1.test.global.canton.network.tradeweb.com"
)

SV_LIST_DEVNET=(
    "https://scan.sv-1.dev.global.canton.network.digitalasset.com"
    "https://scan.sv-2.dev.global.canton.network.digitalasset.com"
    "https://scan.sv.dev.global.canton.network.digitalasset.com"
    "https://scan.sv-1.dev.global.canton.network.sync.global"
    "https://scan.sv-1.dev.global.canton.network.cumberland.io"
)

# Probe all SVs for a network, return first accessible version + set ACCESSIBLE_SCAN_URL
# Sets ACCESSIBLE_SCAN_URL globally if found
ACCESSIBLE_SCAN_URL=""

get_network_version() {
    local network="$1"
    local version=""
    ACCESSIBLE_SCAN_URL=""

    # Lighthouse APIs (public, no whitelist required) — try first
    case "$network" in
        testnet)
            version=$(curl -sf --max-time 10 \
                "https://lighthouse.testnet.cantonloop.com/api/stats" \
                2>/dev/null | grep -oP '"version"\s*:\s*"\K[0-9.]+' | head -1)
            ;;
        devnet)
            version=$(curl -sf --max-time 10 \
                "https://lighthouse.devnet.cantonloop.com/api/stats" \
                2>/dev/null | grep -oP '"version"\s*:\s*"\K[0-9.]+' | head -1)
            ;;
    esac

    # Try each SV scan endpoint — find version AND accessible SV URL
    local sv_list_var="SV_LIST_$(echo "$network" | tr '[:lower:]' '[:upper:]')[@]"
    local sv_list=("${!sv_list_var}")

    for scan_url in "${sv_list[@]}"; do
        local resp
        resp=$(curl -sf --ipv4 --connect-timeout 5 --max-time 10 \
            "${scan_url}/api/scan/version" 2>/dev/null) || continue
        local v
        v=$(echo "$resp" | grep -oP '"version"\s*:\s*"\K[0-9.]+' | head -1)
        if [ -n "$v" ]; then
            ACCESSIBLE_SCAN_URL="$scan_url"
            [ -z "$version" ] && version="$v"
            break
        fi
    done

    # Final fallback — GitHub releases
    if [ -z "$version" ]; then
        version=$(get_latest_version)
        [ -n "$version" ] && warn "No SV reachable, using GitHub latest: $version"
    fi

    echo "$version"
}

# ============================================================
# Fetch onboarding secret from DevNet SV API (auto, no auth needed)
# POST <sv_url>/api/sv/v0/devnet/onboard/validator/prepare
# Returns secret string or empty on failure
# ============================================================
fetch_onboarding_secret_devnet() {
    local scan_url="$1"
    # Convert scan URL to SV URL: scan.sv-X.* → sv.sv-X.*
    local sv_url
    sv_url=$(echo "$scan_url" | sed 's|scan\.|sv.|')

    log "Requesting devnet onboarding secret from $sv_url ..."

    local response http_code
    response=$(curl -s -w "\n%{http_code}" -X POST \
        --connect-timeout 10 --max-time 20 \
        -H "Content-Type: application/json" \
        "${sv_url}/api/sv/v0/devnet/onboard/validator/prepare" 2>/dev/null)

    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | head -n -1)

    if [ "$http_code" = "200" ]; then
        # Response: {"secret": "..."}
        local secret
        secret=$(echo "$body" | python3 -c "import sys,json; print(json.load(sys.stdin).get('secret',''))" 2>/dev/null)
        if [ -n "$secret" ]; then
            echo "$secret"
            return 0
        fi
    fi

    # Try other accessible SVs from the list
    local sv_list_var="SV_LIST_DEVNET[@]"
    local sv_list=("${!sv_list_var}")
    for s_url in "${sv_list[@]}"; do
        [ "$s_url" = "$scan_url" ] && continue
        local sv_url2
        sv_url2=$(echo "$s_url" | sed 's|scan\.|sv.|')
        response=$(curl -s -w "\n%{http_code}" -X POST \
            --connect-timeout 5 --max-time 10 \
            -H "Content-Type: application/json" \
            "${sv_url2}/api/sv/v0/devnet/onboard/validator/prepare" 2>/dev/null)
        http_code=$(echo "$response" | tail -1)
        body=$(echo "$response" | head -n -1)
        if [ "$http_code" = "200" ]; then
            local secret2
            secret2=$(echo "$body" | python3 -c "import sys,json; print(json.load(sys.stdin).get('secret',''))" 2>/dev/null)
            if [ -n "$secret2" ]; then
                echo "$secret2"
                return 0
            fi
        fi
    done

    echo ""
    return 1
}

# ============================================================
# Check SV whitelist status for this server IP
# Must be called after NETWORK is set
# Sets: SV_WHITELISTED (true/false), SV_ACCESSIBLE_URL
# ============================================================
SV_WHITELISTED="false"
SV_ACCESSIBLE_URL=""

check_sv_whitelist() {
    local network="$1"
    local server_ip
    server_ip=$(curl -sf --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')

    echo ""
    log "Checking SV whitelist status for this server (IP: ${server_ip})..."

    local sv_list_var="SV_LIST_$(echo "$network" | tr '[:lower:]' '[:upper:]')[@]"
    local sv_list=("${!sv_list_var}")
    local accessible=()
    local blocked=()

    for scan_url in "${sv_list[@]}"; do
        local http_code
        http_code=$(curl -o /dev/null -s -w "%{http_code}" --ipv4 \
            --connect-timeout 5 --max-time 10 \
            "${scan_url}/api/scan/version" 2>/dev/null || echo "000")

        if [ "$http_code" = "200" ]; then
            accessible+=("$scan_url")
        elif [ "$http_code" = "403" ]; then
            blocked+=("$scan_url")
        fi
        # unreachable (000, timeout) — skip silently
    done

    echo ""
    if [ ${#accessible[@]} -gt 0 ]; then
        SV_WHITELISTED="true"
        SV_ACCESSIBLE_URL="${accessible[0]}"
        echo -e "  ${GREEN}${BOLD}✓ Whitelisted on ${#accessible[@]} SV(s)${NC}"
        for u in "${accessible[@]}"; do
            echo -e "    ${GREEN}●${NC} $u"
        done
        if [ ${#blocked[@]} -gt 0 ]; then
            echo ""
            echo -e "  ${YELLOW}Not whitelisted on ${#blocked[@]} SV(s) — normal, not all SVs need to whitelist you${NC}"
        fi
    else
        SV_WHITELISTED="false"
        echo -e "  ${RED}${BOLD}✗ Not whitelisted on any SV${NC}"
        echo ""
        echo -e "  ${YELLOW}Your server IP ${server_ip} is not whitelisted by any SV on ${network}.${NC}"
        echo -e "  ${YELLOW}The validator will fail to connect to the network without a whitelist entry.${NC}"
        echo ""
        echo -e "  ${BOLD}What to do:${NC}"
        echo ""
        echo -e "  ${BOLD}Option 1 — Request whitelisting from Canton Foundation:${NC}"
        echo -e "    Pedro Neves  <pedro@canton.foundation>"
        echo -e "    Amanda Martin  <amanda@canton.foundation>  (COO)"
        echo ""
        echo -e "  ${BOLD}Option 2 — Fill out the onboarding form:${NC}"
        echo -e "    https://www.canton.network/validators"
        echo ""
        echo -e "  ${BOLD}Option 3 — Use an onboarding secret from an SV that auto-approves:${NC}"
        echo -e "    Some SVs issue onboarding secrets that bypass IP whitelist."
        echo -e "    Ask in the Canton validator community or contact the SVs above."
        echo ""
        echo -e "  Include in your request:"
        echo -e "    • Server IP: ${server_ip}"
        echo -e "    • Network: ${network}"
        echo -e "    • Party hint: your validator name"
        echo ""

        local proceed
        read -rp "$(echo -e "${YELLOW}Continue installation anyway? (validator won't start until whitelisted) [y/N]${NC}: ")" proceed
        if [[ ! "$proceed" =~ ^[Yy]$ ]]; then
            echo ""
            log "Installation cancelled. Come back after getting whitelisted."
            exit 0
        fi
        echo ""
        warn "Proceeding without whitelist — validator will retry connection automatically once whitelisted"
    fi
    echo ""
}

get_our_version() {
    docker inspect splice-validator-validator-1 \
        --format '{{.Config.Image}}' 2>/dev/null \
        | grep -oP ':\K[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

version_gte() {
    [ "$(printf '%s\n%s' "$1" "$2" | sort -V | tail -1)" = "$1" ]
}

# ============================================================
# Main menu
# ============================================================
main_menu() {
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║   Canton Validator Toolkit                   ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
    echo ""

    # If already installed — show current state
    if [ -f "$TOOLKIT_CONF" ]; then
        source "$TOOLKIT_CONF"
        local our_version
        our_version=$(get_our_version 2>/dev/null || echo "unknown")
        local net_version
        net_version=$(get_network_version "${NETWORK:-mainnet}" 2>/dev/null || echo "unknown")

        echo -e "  Current version : ${BOLD}${our_version}${NC}"
        echo -e "  Network version : ${BOLD}${net_version}${NC}"
        echo -e "  Network         : ${NETWORK:-?}"
        echo -e "  Party hint      : ${PARTY_HINT:-?}"
        echo ""

        if [ "$our_version" != "unknown" ] && [ "$net_version" != "unknown" ] && \
           [ "$our_version" != "$net_version" ]; then
            echo -e "  ${YELLOW}⚠ Update available: $our_version → $net_version${NC}"
            echo ""
        fi
    fi

    echo -e "${BOLD}What do you want to do?${NC}"
    echo "  1) Install Canton validator (fresh setup)"
    echo "  2) Update to latest version"
    echo "  3) Show status"
    echo "  4) Exit"
    echo ""
    local choice
    read -rp "$(echo -e "${BOLD}Choice [1-4]${NC}: ")" choice

    case "$choice" in
        1) mode_install ;;
        2) mode_update ;;
        3) mode_status ;;
        4) exit 0 ;;
        *) die "Invalid choice" ;;
    esac
}

# ============================================================
# Mode: STATUS
# ============================================================
mode_status() {
    echo ""
    echo -e "${BOLD}═══════════════════ Status ═══════════════════${NC}"

    if [ ! -f "$TOOLKIT_CONF" ]; then
        warn "Not installed — toolkit.conf not found"
        return
    fi

    source "$TOOLKIT_CONF"

    local our_version
    our_version=$(get_our_version 2>/dev/null || echo "not running")
    local net_version
    net_version=$(get_network_version "${NETWORK:-mainnet}" 2>/dev/null || echo "unavailable")

    echo ""
    echo -e "  ${BOLD}Network:${NC}         $NETWORK"
    echo -e "  ${BOLD}Our version:${NC}     $our_version"
    echo -e "  ${BOLD}Network version:${NC} $net_version"
    echo -e "  ${BOLD}Party hint:${NC}      $PARTY_HINT"
    echo -e "  ${BOLD}Auto-upgrade:${NC}    ${AUTO_UPGRADE:-false}"
    echo ""

    echo -e "  ${BOLD}Containers:${NC}"
    for c in splice-validator-validator-1 splice-validator-participant-1 splice-validator-nginx-1; do
        local running health
        running=$(docker inspect --format='{{.State.Running}}' "$c" 2>/dev/null || echo "false")
        health=$(docker inspect --format='{{.State.Health.Status}}' "$c" 2>/dev/null || echo "n/a")
        if [ "$running" = "true" ]; then
            echo -e "    ${GREEN}●${NC} $c [$health]"
        else
            echo -e "    ${RED}●${NC} $c [down]"
        fi
    done
    echo ""

    if [ "$our_version" != "not running" ] && [ "$net_version" != "unavailable" ]; then
        if version_gte "$net_version" "$our_version" && [ "$our_version" != "$net_version" ]; then
            echo -e "  ${YELLOW}⚠ Update available: $our_version → $net_version${NC}"
            echo -e "  Run: $(basename "$0") → option 2 to update"
        else
            echo -e "  ${GREEN}✓ Version is up to date${NC}"
        fi
    fi
    echo ""
}

# ============================================================
# Mode: INSTALL — collect full input
# ============================================================
collect_install_input() {
    echo ""
    echo -e "${BOLD}─── Fresh Installation ─────────────────────────${NC}"
    echo ""

    # 1. Network
    echo -e "${BOLD}Select network:${NC}"
    echo "  1) mainnet"
    echo "  2) testnet"
    echo "  3) devnet"
    local net_choice
    read -rp "$(echo -e "${BOLD}Choice [1-3]${NC}: ")" net_choice
    case "$net_choice" in
        1) NETWORK="mainnet" ;;
        2) NETWORK="testnet" ;;
        3) NETWORK="devnet" ;;
        *) die "Invalid choice" ;;
    esac

    case "$NETWORK" in
        mainnet)
            DEFAULT_SV="https://sv.sv-2.global.canton.network.digitalasset.com"
            DEFAULT_SCAN="https://scan.sv-2.global.canton.network.digitalasset.com"
            DEFAULT_MIGRATION="4"
            ;;
        testnet)
            DEFAULT_SV="https://sv.sv-2.test.global.canton.network.digitalasset.com"
            DEFAULT_SCAN="https://scan.sv-2.test.global.canton.network.digitalasset.com"
            DEFAULT_MIGRATION="1"
            ;;
        devnet)
            DEFAULT_SV="https://sv.sv-2.dev.global.canton.network.digitalasset.com"
            DEFAULT_SCAN="https://scan.sv-2.dev.global.canton.network.digitalasset.com"
            DEFAULT_MIGRATION="1"
            ;;
    esac

    # Check SV whitelist before anything else
    check_sv_whitelist "$NETWORK"

    # If an accessible SV was found — use it as default SV/Scan URL
    if [ -n "$SV_ACCESSIBLE_URL" ]; then
        local sv_base
        sv_base=$(echo "$SV_ACCESSIBLE_URL" | sed 's|scan\.|sv.|')
        DEFAULT_SV="$sv_base"
        DEFAULT_SCAN="$SV_ACCESSIBLE_URL"
    fi

    echo ""
    log "Detecting latest Canton version for $NETWORK..."
    VERSION=$(get_network_version "$NETWORK")
    if [ -z "$VERSION" ]; then
        warn "Could not detect network version, trying GitHub latest..."
        VERSION=$(get_latest_version)
    fi
    [ -z "$VERSION" ] && die "Cannot detect Canton version. Check network connectivity."
    success "Canton version: $VERSION"

    # 2. Party hint
    echo ""
    prompt PARTY_HINT "Party hint (e.g. MyOrg-validator-1)" ""
    [ -z "$PARTY_HINT" ] && die "Party hint cannot be empty"

    # 3. Migration ID
    prompt MIGRATION_ID "Migration ID" "$DEFAULT_MIGRATION"

    # 4. SV URL
    prompt SV_URL "SV sponsor URL" "$DEFAULT_SV"

    # 5. Scan URL
    prompt SCAN_URL "Scan URL" "$DEFAULT_SCAN"

    # 6. Onboarding secret
    echo ""
    ONBOARDING_SECRET=""

    # Check if already onboarded (validator container was running before)
    local already_onboarded="false"
    if docker inspect splice-validator-validator-1 &>/dev/null 2>&1; then
        already_onboarded="true"
    fi

    if [ "$already_onboarded" = "true" ]; then
        success "Validator already onboarded — skipping onboarding secret"
        ONBOARDING_SECRET=""
    elif [ "$NETWORK" = "devnet" ] && [ "$SV_WHITELISTED" = "true" ] && [ -n "$SV_ACCESSIBLE_URL" ]; then
        # DevNet + whitelisted — offer auto-request via API
        echo -e "${BOLD}Onboarding secret — DevNet auto-request available${NC}"
        echo -e "  Your server is whitelisted on: ${GREEN}$SV_ACCESSIBLE_URL${NC}"
        echo -e "  DevNet allows fetching a secret automatically via SV API."
        echo -e "  ${YELLOW}Note: secret is valid for 1 hour, single use.${NC}"
        echo ""
        local secret_choice
        read -rp "$(echo -e "${BOLD}Fetch onboarding secret automatically? [Y/n]${NC}: ")" secret_choice
        if [[ ! "$secret_choice" =~ ^[Nn]$ ]]; then
            ONBOARDING_SECRET=$(fetch_onboarding_secret_devnet "$SV_ACCESSIBLE_URL")
            if [ -n "$ONBOARDING_SECRET" ]; then
                success "Onboarding secret obtained"
            else
                warn "Auto-fetch failed — enter secret manually (or leave empty if already onboarded)"
                prompt ONBOARDING_SECRET "Onboarding secret" ""
            fi
        else
            prompt ONBOARDING_SECRET "Onboarding secret (empty if already onboarded)" ""
        fi
    else
        # TestNet / MainNet / not whitelisted — always manual
        if [ "$NETWORK" = "mainnet" ]; then
            echo -e "  ${BOLD}MainNet:${NC} request onboarding secret from your SV sponsor."
        elif [ "$NETWORK" = "testnet" ]; then
            echo -e "  ${BOLD}TestNet:${NC} request onboarding secret from your SV sponsor."
            echo -e "  Leave empty if already onboarded."
        fi
        echo ""
        prompt ONBOARDING_SECRET "Onboarding secret (empty if already onboarded)" ""
    fi

    # 7. Node name
    local default_node_name="${PARTY_HINT}-$(echo "$NETWORK" | tr '[:lower:]' '[:upper:]')"
    prompt NODE_NAME "Node name (for alerts)" "$default_node_name"

    # 8. Wallet password
    echo ""
    prompt_secret WALLET_PASSWORD "Wallet nginx basic auth password (username: validator)"
    [ -z "$WALLET_PASSWORD" ] && die "Password cannot be empty"

    # 9. Backup
    echo ""
    echo -e "${BOLD}Backup target:${NC}"
    echo "  1) rsync (SSH to remote server)"
    echo "  2) r2 (Cloudflare R2)"
    echo "  3) skip"
    local backup_choice
    read -rp "$(echo -e "${BOLD}Choice [1-3]${NC}: ")" backup_choice
    case "$backup_choice" in
        1)
            BACKUP_TYPE="rsync"
            prompt REMOTE_HOST "Remote host (user@host)" ""
            prompt REMOTE_PATH "Remote path" "~/canton-backups/$NETWORK"
            R2_BUCKET=""; R2_ACCOUNT_ID=""; R2_ACCESS_KEY=""; R2_SECRET_KEY=""
            ;;
        2)
            BACKUP_TYPE="r2"
            prompt R2_BUCKET    "R2 bucket name" ""
            prompt R2_ACCOUNT_ID "R2 account ID" ""
            prompt R2_ACCESS_KEY "R2 access key" ""
            prompt_secret R2_SECRET_KEY "R2 secret key"
            REMOTE_HOST=""; REMOTE_PATH=""
            ;;
        *)
            BACKUP_TYPE="skip"
            REMOTE_HOST=""; REMOTE_PATH=""
            R2_BUCKET=""; R2_ACCOUNT_ID=""; R2_ACCESS_KEY=""; R2_SECRET_KEY=""
            ;;
    esac
    local retention_input
    prompt retention_input "Backup retention (days)" "1"
    # ensure it's a number, default to 1 if user entered non-numeric
    if [[ "$retention_input" =~ ^[0-9]+$ ]]; then
        RETENTION_DAYS="$retention_input"
    else
        RETENTION_DAYS="1"
    fi

    # 10. Telegram
    echo ""
    local tg_choice
    read -rp "$(echo -e "${BOLD}Enable Telegram alerts? [y/N]${NC}: ")" tg_choice
    if [[ "$tg_choice" =~ ^[Yy]$ ]]; then
        prompt TELEGRAM_BOT_TOKEN "Telegram bot token" ""
        prompt TELEGRAM_CHAT_ID  "Telegram chat ID"   ""
    else
        TELEGRAM_BOT_TOKEN=""; TELEGRAM_CHAT_ID=""
    fi

    # 11. Auto-upgrade (default: NO)
    echo ""
    echo -e "${BOLD}Auto-upgrade cron (runs daily at 22:00)?${NC}"
    echo -e "  Default: ${YELLOW}NO${NC} — upgrades run manually via this script"
    local au_choice
    read -rp "$(echo -e "${BOLD}Enable auto-upgrade? [y/N]${NC}: ")" au_choice
    [[ "$au_choice" =~ ^[Yy]$ ]] && AUTO_UPGRADE="true" || AUTO_UPGRADE="false"

    # 12. Monitoring stack
    echo ""
    local mon_choice
    read -rp "$(echo -e "${BOLD}Install Grafana monitoring stack? [y/N]${NC}: ")" mon_choice
    [[ "$mon_choice" =~ ^[Yy]$ ]] && MONITORING="true" || MONITORING="false"

    # 13. Cloudflare tunnel
    echo ""
    local cf_choice
    read -rp "$(echo -e "${BOLD}Configure Cloudflare Tunnel for wallet access? [y/N]${NC}: ")" cf_choice
    if [[ "$cf_choice" =~ ^[Yy]$ ]]; then
        CLOUDFLARE_TUNNEL="true"
        prompt CLOUDFLARE_DOMAIN "Wallet domain (e.g. wallet.yourdomain.com)" ""
    else
        CLOUDFLARE_TUNNEL="false"; CLOUDFLARE_DOMAIN=""
    fi

    # Summary
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════${NC}"
    echo -e "${BOLD} Configuration Summary${NC}"
    echo -e "${BOLD}═══════════════════════════════════════${NC}"
    echo "  Network:      $NETWORK"
    echo "  Version:      $VERSION"
    echo "  Party hint:   $PARTY_HINT"
    echo "  Migration ID: $MIGRATION_ID"
    echo "  SV URL:       $SV_URL"
    echo "  Scan URL:     $SCAN_URL"
    echo "  Backup:       $BACKUP_TYPE"
    echo "  Telegram:     $([ -n "$TELEGRAM_BOT_TOKEN" ] && echo "yes" || echo "no")"
    echo "  Auto-upgrade: $AUTO_UPGRADE"
    echo "  Monitoring:   $MONITORING"
    echo "  CF Tunnel:    $CLOUDFLARE_TUNNEL"
    echo ""
    local confirm
    read -rp "$(echo -e "${BOLD}Proceed with installation? [y/N]${NC}: ")" confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || die "Installation cancelled"
}

mode_install() {
    collect_install_input

    mkdir -p "$CANTON_DIR" "$LOG_DIR"

    local validator_dir="$CANTON_DIR/$VERSION/splice-node/docker-compose/validator"

    download_bundle "$VERSION"
    write_env "$validator_dir" "$VERSION"
    write_nginx_conf "$validator_dir"
    write_htpasswd "$validator_dir"
    patch_compose "$validator_dir"
    save_toolkit_conf "$VERSION"
    update_symlink "$VERSION"
    start_validator "$validator_dir" "$VERSION"
    wait_healthy || true
    setup_cron
    install_monitoring
    install_cloudflare
    send_telegram "✅ <b>${NODE_NAME}</b>%0A%0ACanton ${VERSION} installed on $(hostname)%0ANetwork: ${NETWORK}%0AParty: ${PARTY_HINT}"
    print_access_info "$VERSION"
}

# ============================================================
# Mode: UPDATE — manual upgrade with minimum downtime
# ============================================================
mode_update() {
    if [ ! -f "$TOOLKIT_CONF" ]; then
        die "Not installed yet — run install first (option 1)"
    fi

    source "$TOOLKIT_CONF"

    echo ""
    echo -e "${BOLD}─── Manual Update ───────────────────────────────${NC}"
    echo ""

    # Detect versions
    log "Detecting versions..."
    local our_version net_version
    our_version=$(get_our_version 2>/dev/null || echo "")
    net_version=$(get_network_version "$NETWORK" 2>/dev/null || echo "")

    if [ -z "$our_version" ]; then
        die "Cannot detect running version — is the validator running?"
    fi
    if [ -z "$net_version" ]; then
        warn "Cannot detect network version. Enter version manually:"
        prompt net_version "Target version (e.g. 0.5.11)" ""
        [ -z "$net_version" ] && die "Version cannot be empty"
    fi

    echo ""
    echo -e "  Running : ${BOLD}$our_version${NC}"
    echo -e "  Target  : ${BOLD}$net_version${NC}"
    echo ""

    if [ "$our_version" = "$net_version" ]; then
        success "Already on $our_version — nothing to do"
        return
    fi

    if version_gte "$our_version" "$net_version"; then
        warn "Running version ($our_version) is newer than network ($net_version)"
        local force_choice
        read -rp "$(echo -e "${BOLD}Force upgrade anyway? [y/N]${NC}: ")" force_choice
        [[ "$force_choice" =~ ^[Yy]$ ]] || { log "Cancelled"; return; }
    fi

    # Major version warning
    local our_major net_major
    our_major=$(echo "$our_version" | cut -d. -f1-2)
    net_major=$(echo "$net_version" | cut -d. -f1-2)
    if [ "$our_major" != "$net_major" ]; then
        echo ""
        echo -e "${RED}${BOLD}  ⚠ MAJOR version change: $our_version → $net_version${NC}"
        echo -e "${RED}  This may require manual migration steps.${NC}"
        echo -e "${RED}  Check release notes before proceeding.${NC}"
        echo ""
        local major_confirm
        read -rp "$(echo -e "${BOLD}Proceed with major upgrade? [y/N]${NC}: ")" major_confirm
        [[ "$major_confirm" =~ ^[Yy]$ ]] || { log "Cancelled"; return; }
    fi

    # Backup before upgrade?
    echo ""
    local backup_choice
    read -rp "$(echo -e "${BOLD}Run backup before upgrade? [Y/n]${NC}: ")" backup_choice
    if [[ ! "$backup_choice" =~ ^[Nn]$ ]]; then
        if [ -f "$TOOLKIT_DIR/scripts/backup.sh" ] && [ "$BACKUP_TYPE" != "skip" ]; then
            log "Running backup..."
            bash "$TOOLKIT_DIR/scripts/backup.sh" || {
                echo ""
                local skip_choice
                read -rp "$(echo -e "${YELLOW}Backup failed. Continue anyway? [y/N]${NC}: ")" skip_choice
                [[ "$skip_choice" =~ ^[Yy]$ ]] || die "Upgrade aborted"
            }
        else
            warn "Backup skipped (type=skip or backup.sh not found)"
        fi
    fi

    echo ""
    read -rp "$(echo -e "${BOLD}Start upgrade $our_version → $net_version now? [y/N]${NC}: ")" go
    [[ "$go" =~ ^[Yy]$ ]] || { log "Cancelled"; return; }

    do_upgrade "$our_version" "$net_version"
}

# ============================================================
# Core upgrade logic (shared by manual update + auto_upgrade)
# Minimum downtime: download + prepull while old node runs,
# then stop old → start new → verify → rollback if unhealthy
# ============================================================
do_upgrade() {
    local old_version="$1"
    local new_version="$2"
    local new_dir="$CANTON_DIR/$new_version/splice-node/docker-compose/validator"
    local old_dir="$CANTON_DIR/$old_version/splice-node/docker-compose/validator"

    send_telegram "🔄 <b>${NODE_NAME:-Canton}</b>%0A%0AUpgrade starting: ${old_version} → ${new_version}%0AHost: $(hostname)"

    # ── Step 1: Download bundle ──────────────────────────────
    log "[1/6] Downloading bundle v${new_version}..."
    download_bundle "$new_version"

    # ── Step 2: Migrate config ───────────────────────────────
    log "[2/6] Migrating config from $old_version..."
    cp "$old_dir/.env" "$new_dir/.env"

    if [ -f "$old_dir/nginx.conf" ]; then
        cp "$old_dir/nginx.conf" "$new_dir/nginx.conf"
    else
        warn "nginx.conf not found in old version — writing from template"
        write_nginx_conf "$new_dir"
    fi

    if [ -d "$old_dir/nginx" ]; then
        cp -r "$old_dir/nginx" "$new_dir/nginx"
        success ".htpasswd copied"
    fi

    # ── Step 3: Patch .env + compose.yaml ────────────────────
    log "[3/6] Patching .env and compose.yaml..."
    patch_env "$new_dir" "$new_version"
    patch_compose "$new_dir"

    # ── Step 4: Pre-pull images (old node still running!) ────
    log "[4/6] Pre-pulling images for v${new_version}..."
    log "      Old validator is still running during this step"
    cd "$new_dir"
    export IMAGE_TAG="$new_version"
    if ! docker compose --env-file .env pull 2>&1 | tail -3; then
        die "Image pull failed — upgrade aborted, old version still running"
    fi
    success "Images pulled"

    # ── Step 5: Stop old, start new ──────────────────────────
    log "[5/6] Stopping v${old_version}..."
    cd "$old_dir"
    export IMAGE_TAG="$old_version"
    ./stop.sh 2>/dev/null || docker compose down 2>/dev/null || true
    success "v${old_version} stopped"

    log "      Starting v${new_version}..."
    cd "$new_dir"
    export IMAGE_TAG="$new_version"

    local onboarding_secret="${ONBOARDING_SECRET:-}"
    local start_args="-s $SV_URL -c $SCAN_URL -p $PARTY_HINT -m $MIGRATION_ID -o \"$onboarding_secret\" -w"

    if ! eval ./start.sh $start_args; then
        error "Start failed — attempting rollback to $old_version"
        _rollback "$old_version"
        die "Upgrade failed, rolled back to $old_version"
    fi

    # ── Step 6: Verify health ─────────────────────────────────
    log "[6/6] Waiting for validator to become healthy..."
    local attempts=0
    local healthy=false
    while [ $attempts -lt 9 ]; do
        sleep 10
        attempts=$((attempts + 1))
        local status
        status=$(docker inspect --format='{{.State.Health.Status}}' \
            splice-validator-validator-1 2>/dev/null || echo "not_found")
        log "      [$attempts/9] status: $status"
        if [ "$status" = "healthy" ]; then
            healthy=true
            break
        fi
    done

    if [ "$healthy" = "true" ]; then
        # Update symlink + toolkit.conf
        ln -sfn "$CANTON_DIR/$new_version" "$CANTON_DIR/current"
        if grep -q "^VERSION=" "$TOOLKIT_CONF"; then
            sed -i "s|^VERSION=.*|VERSION=${new_version}|" "$TOOLKIT_CONF"
        else
            echo "VERSION=${new_version}" >> "$TOOLKIT_CONF"
        fi

        success "Upgrade complete: $old_version → $new_version"
        send_telegram "✅ <b>${NODE_NAME:-Canton}</b>%0A%0AUpgrade SUCCESS: ${old_version} → ${new_version}%0AValidator: healthy%0AHost: $(hostname)"

        echo ""
        echo -e "${GREEN}${BOLD}  ✓ Upgrade successful!${NC}"
        echo -e "  Version: ${BOLD}$new_version${NC}"
        echo ""
    else
        error "Validator unhealthy after upgrade — rolling back to $old_version"
        send_telegram "❌ <b>${NODE_NAME:-Canton}</b>%0A%0AUpgrade FAILED (unhealthy)%0ARolling back to ${old_version}..."
        _stop_version "$new_version"
        _rollback "$old_version"
        die "Rolled back to $old_version"
    fi
}

_stop_version() {
    local version="$1"
    local dir="$CANTON_DIR/$version/splice-node/docker-compose/validator"
    [ -d "$dir" ] || return
    cd "$dir"
    export IMAGE_TAG="$version"
    ./stop.sh 2>/dev/null || docker compose down 2>/dev/null || true
}

_rollback() {
    local version="$1"
    local dir="$CANTON_DIR/$version/splice-node/docker-compose/validator"
    [ -d "$dir" ] || { error "Rollback dir not found: $dir"; return 1; }

    log "Rolling back to $version..."
    cd "$dir"
    export IMAGE_TAG="$version"

    local onboarding_secret="${ONBOARDING_SECRET:-}"
    local start_args="-s $SV_URL -c $SCAN_URL -p $PARTY_HINT -m $MIGRATION_ID -o \"$onboarding_secret\" -w"

    if eval ./start.sh $start_args; then
        send_telegram "🔙 <b>${NODE_NAME:-Canton}</b>%0ARolled back to ${version} successfully"
        success "Rollback to $version complete"
    else
        send_telegram "❌ <b>${NODE_NAME:-Canton}</b>%0ARollback to ${version} FAILED — manual intervention required!"
        error "Rollback failed — check manually"
    fi
}

# ============================================================
# Download Canton bundle
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
    log "Downloading Canton $version..."

    if ! curl -fL --progress-bar "$bundle_url" -o "${version}_splice-node.tar.gz"; then
        rm -f "${version}_splice-node.tar.gz"
        die "Download failed: $bundle_url"
    fi

    log "Extracting bundle..."
    tar xzf "${version}_splice-node.tar.gz"
    rm -f "${version}_splice-node.tar.gz"
    success "Bundle extracted to $target_dir"
}

# ============================================================
# Write .env
# ============================================================
write_env() {
    local validator_dir="$1"
    local version="$2"

    log "Writing .env..."
    cat > "$validator_dir/.env" <<ENVEOF
IMAGE_REPO=ghcr.io/digital-asset/decentralized-canton-sync/docker/
SPLICE_POSTGRES_VERSION=14
NGINX_VERSION=1.27.1
SPLICE_DB_USER=cnadmin
SPLICE_DB_PASSWORD=supersafe
SPLICE_DB_SERVER=postgres-splice
SPLICE_DB_PORT=5432
TARGET_TRAFFIC_THROUGHPUT=20000
MIN_TRAFFIC_TOPUP_INTERVAL=1m
IMAGE_TAG=${version}
MIGRATION_ID=${MIGRATION_ID}
SPONSOR_SV_ADDRESS=${SV_URL}
SCAN_ADDRESS=${SCAN_URL}
PARTY_HINT=${PARTY_HINT}
PARTICIPANT_IDENTIFIER=${PARTY_HINT}
CONTACT_POINT=
ONBOARDING_SECRET=${ONBOARDING_SECRET:-}
AUTH_URL=https://unsafe.auth
COMPOSE_FILE=compose.yaml:compose-disable-auth.yaml
SPLICE_APP_UI_NETWORK_NAME=Canton Network
SPLICE_APP_UI_NETWORK_FAVICON_URL=https://www.canton.network/hubfs/cn-favicon-05%201-1.png
SPLICE_APP_UI_AMULET_NAME=Canton Coin
SPLICE_APP_UI_AMULET_NAME_ACRONYM=CC
SPLICE_APP_UI_NAME_SERVICE_NAME=Canton Name Service
SPLICE_APP_UI_NAME_SERVICE_NAME_ACRONYM=CNS
ENVEOF
    success ".env written"
}

# ============================================================
# Patch .env on upgrade (preserves existing values, adds missing)
# ============================================================
patch_env() {
    local validator_dir="$1"
    local version="$2"
    local env_file="$validator_dir/.env"

    # IMAGE_TAG
    if grep -q "^IMAGE_TAG=" "$env_file"; then
        sed -i "s|^IMAGE_TAG=.*|IMAGE_TAG=${version}|" "$env_file"
    else
        echo "IMAGE_TAG=${version}" >> "$env_file"
    fi

    # AUTH_URL — must not be empty
    if grep -qE '^AUTH_URL=(""|)$' "$env_file"; then
        sed -i 's|^AUTH_URL=.*|AUTH_URL=https://unsafe.auth|' "$env_file"
    fi
    grep -q "^AUTH_URL=" "$env_file" || echo "AUTH_URL=https://unsafe.auth" >> "$env_file"

    # COMPOSE_FILE
    grep -q "^COMPOSE_FILE=" "$env_file" || \
        echo "COMPOSE_FILE=compose.yaml:compose-disable-auth.yaml" >> "$env_file"

    # SPLICE_APP_UI_* — all 6 vars required (ZodError prevention)
    if ! grep -q "^SPLICE_APP_UI_NETWORK_NAME=" "$env_file"; then
        printf '\n# UI Branding\nSPLICE_APP_UI_NETWORK_NAME=Canton Network\nSPLICE_APP_UI_NETWORK_FAVICON_URL=https://www.canton.network/hubfs/cn-favicon-05%%201-1.png\nSPLICE_APP_UI_AMULET_NAME=Canton Coin\nSPLICE_APP_UI_AMULET_NAME_ACRONYM=CC\nSPLICE_APP_UI_NAME_SERVICE_NAME=Canton Name Service\nSPLICE_APP_UI_NAME_SERVICE_NAME_ACRONYM=CNS\n' \
            >> "$env_file"
        success "SPLICE_APP_UI_* vars added"
    fi

    success ".env patched"
}

# ============================================================
# Write nginx.conf from template
# ============================================================
write_nginx_conf() {
    local validator_dir="$1"

    log "Writing nginx.conf..."
    cat > "$validator_dir/nginx.conf" <<'NGINXEOF'
events { worker_connections 64; }

http {
  server {
    listen 80;
    server_name wallet.localhost;
    auth_basic "Wallet Access";
    auth_basic_user_file /etc/nginx/includes/.htpasswd;
    location /api/validator {
      auth_basic off;
      rewrite ^\/(.*)  /$1 break;
      proxy_pass http://validator:5003/api/validator;
    }
    location / { proxy_pass http://wallet-web-ui:8080/; }
  }
  server {
    listen 80;
    server_name ans.localhost;
    auth_basic "ANS Access";
    auth_basic_user_file /etc/nginx/includes/.htpasswd;
    location /api/validator {
      auth_basic off;
      rewrite ^\/(.*)  /$1 break;
      proxy_pass http://validator:5003/api/validator;
    }
    location / { proxy_pass http://ans-web-ui:8080/; }
  }
  server {
    listen 80;
    server_name validator.localhost;
    location /metrics { proxy_pass http://validator:10013/metrics; }
  }
  server {
    listen 80;
    server_name participant.localhost;
    location /metrics { proxy_pass http://participant:10013/metrics; }
  }
  server {
    listen 80;
    server_name json-ledger-api.localhost;
    location / { proxy_pass http://participant:7575; }
  }
  server {
    listen 80 http2;
    server_name grpc-ledger-api.localhost;
    location / { grpc_pass grpc://participant:5001; }
  }
}
NGINXEOF
    success "nginx.conf written"
}

# ============================================================
# Write .htpasswd
# ============================================================
write_htpasswd() {
    local validator_dir="$1"

    mkdir -p "$validator_dir/nginx"
    local hash
    hash=$(openssl passwd -apr1 "$WALLET_PASSWORD")
    printf 'validator:%s\n' "$hash" > "$validator_dir/nginx/.htpasswd"
    success ".htpasswd written (user: validator)"
}

# ============================================================
# Patch compose.yaml (port 80 → 8888 on 127.0.0.1)
# ============================================================
patch_compose() {
    local validator_dir="$1"
    local compose_file="$validator_dir/compose.yaml"

    [ ! -f "$compose_file" ] && warn "compose.yaml not found, skipping port patch" && return

    sed -i 's|"${HOST_BIND_IP:-0\.0\.0\.0}:80:80"|"${HOST_BIND_IP:-127.0.0.1}:8888:80"|g' "$compose_file"
    sed -i 's|"${HOST_BIND_IP:-127\.0\.0\.1}:80:80"|"${HOST_BIND_IP:-127.0.0.1}:8888:80"|g' "$compose_file"
    sed -i 's|"0\.0\.0\.0:80:80"|"127.0.0.1:8888:80"|g' "$compose_file"
    sed -i 's|"127\.0\.0\.1:80:80"|"127.0.0.1:8888:80"|g' "$compose_file"
    success "compose.yaml patched (port 8888)"
}

# ============================================================
# Save toolkit.conf
# ============================================================
save_toolkit_conf() {
    local version="$1"

    log "Saving toolkit.conf..."
    mkdir -p "$CANTON_DIR"
    cat > "$TOOLKIT_CONF" <<CONFEOF
# Canton Validator Toolkit — configuration
# Written by setup.sh on $(date -u '+%Y-%m-%d %H:%M:%S UTC')

NETWORK=${NETWORK}
VERSION=${version}
PARTY_HINT=${PARTY_HINT}
MIGRATION_ID=${MIGRATION_ID}
SV_URL=${SV_URL}
SCAN_URL=${SCAN_URL}
NODE_NAME=${NODE_NAME}
BACKUP_TYPE=${BACKUP_TYPE}
REMOTE_HOST=${REMOTE_HOST:-}
REMOTE_PATH=${REMOTE_PATH:-}
R2_BUCKET=${R2_BUCKET:-}
R2_ACCOUNT_ID=${R2_ACCOUNT_ID:-}
R2_ACCESS_KEY=${R2_ACCESS_KEY:-}
R2_SECRET_KEY=${R2_SECRET_KEY:-}
RETENTION_DAYS=${RETENTION_DAYS}
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN:-}
TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID:-}
AUTO_UPGRADE=${AUTO_UPGRADE:-false}
MONITORING=${MONITORING}
CLOUDFLARE_TUNNEL=${CLOUDFLARE_TUNNEL}
CLOUDFLARE_DOMAIN=${CLOUDFLARE_DOMAIN:-}
CANTON_NETWORK_NAME=${CANTON_NETWORK_NAME:-splice-validator}
AUTO_RESTART=true
WAIT_HOURS=12
TOOLKIT_DIR=${TOOLKIT_DIR}
CONFEOF
    chmod 600 "$TOOLKIT_CONF"
    success "toolkit.conf saved"
}

# ============================================================
# Update current symlink
# ============================================================
update_symlink() {
    local version="$1"
    ln -sfn "$CANTON_DIR/$version" "$CANTON_DIR/current"
    success "Symlink: ~/.canton/current → $version"
}

# ============================================================
# Setup cron jobs
# ============================================================
setup_cron() {
    log "Setting up cron jobs..."
    mkdir -p "$LOG_DIR"

    local tmpfile
    tmpfile=$(mktemp)

    # Remove old toolkit entries
    crontab -l 2>/dev/null \
        | grep -v "canton-validator-toolkit\|check_health.sh\|auto_upgrade.sh\|backup.sh" \
        > "$tmpfile" || true

    # Health check — always
    echo "*/15 * * * * $TOOLKIT_DIR/scripts/check_health.sh >> $LOG_DIR/health.log 2>&1" >> "$tmpfile"

    # Backup — if not skip
    if [ "${BACKUP_TYPE:-skip}" != "skip" ]; then
        echo "0 */4 * * * $TOOLKIT_DIR/scripts/backup.sh >> $LOG_DIR/backup.log 2>&1" >> "$tmpfile"
    fi

    # Auto-upgrade — only if explicitly enabled
    if [ "${AUTO_UPGRADE:-false}" = "true" ]; then
        echo "0 22 * * * $TOOLKIT_DIR/scripts/auto_upgrade.sh >> $LOG_DIR/upgrade.log 2>&1" >> "$tmpfile"
        success "Auto-upgrade cron enabled (daily 22:00)"
    else
        log "Auto-upgrade cron: disabled (run upgrade manually via setup.sh → option 2)"
    fi

    crontab "$tmpfile"
    rm -f "$tmpfile"
    success "Cron jobs installed"
}

# ============================================================
# Start validator (fresh install)
# ============================================================
start_validator() {
    local validator_dir="$1"
    local version="$2"

    log "Starting Canton validator $version..."
    cd "$validator_dir"
    export IMAGE_TAG="$version"

    local onboarding_secret="${ONBOARDING_SECRET:-}"
    local start_args="-s $SV_URL -c $SCAN_URL -p $PARTY_HINT -m $MIGRATION_ID -o \"$onboarding_secret\" -w"

    eval ./start.sh $start_args || die "Failed to start validator. Check: docker compose logs"
    success "Validator started"
}

# ============================================================
# Wait for healthy
# ============================================================
wait_healthy() {
    log "Waiting for validator to become healthy (up to 3 minutes)..."
    local attempts=0

    while [ $attempts -lt 18 ]; do
        local status
        status=$(docker inspect --format='{{.State.Health.Status}}' \
            splice-validator-validator-1 2>/dev/null || echo "not_found")
        [ "$status" = "healthy" ] && success "Validator is healthy" && return 0
        attempts=$((attempts + 1))
        echo -n "  [$attempts/18] $status — 10s..."
        sleep 10
        echo ""
    done

    warn "Validator not healthy after 3 minutes — check: docker compose logs validator"
    return 1
}

# ============================================================
# Install monitoring stack
# ============================================================
install_monitoring() {
    [ "${MONITORING:-false}" != "true" ] && return 0

    log "Starting monitoring stack..."
    local mon_compose="$TOOLKIT_DIR/monitoring/docker-compose.yml"

    if [ ! -f "$mon_compose" ]; then
        warn "monitoring/docker-compose.yml not found, skipping"
        return 0
    fi

    # Auto-detect Canton docker network name from running containers
    local net_name
    net_name=$(docker network ls --format '{{.Name}}' \
        | grep '_splice_validator$' | head -1 \
        | sed 's/_splice_validator$//')
    if [ -z "$net_name" ]; then
        net_name="${CANTON_NETWORK_NAME:-splice-validator}"
        warn "Could not auto-detect network name, using: $net_name"
    else
        success "Detected Canton network: ${net_name}_splice_validator"
    fi
    CANTON_NETWORK_NAME="$net_name"

    # Persist detected name to toolkit.conf
    if grep -q "^CANTON_NETWORK_NAME=" "$TOOLKIT_CONF" 2>/dev/null; then
        sed -i "s|^CANTON_NETWORK_NAME=.*|CANTON_NETWORK_NAME=${net_name}|" "$TOOLKIT_CONF"
    fi

    cd "$TOOLKIT_DIR/monitoring"
    CANTON_NETWORK_NAME="$net_name" docker compose up -d
    success "Monitoring started — Grafana: http://127.0.0.1:3001 (admin/admin)"
}

# ============================================================
# Install Cloudflare tunnel
# ============================================================
install_cloudflare() {
    [ "${CLOUDFLARE_TUNNEL:-false}" != "true" ] || [ -z "${CLOUDFLARE_DOMAIN:-}" ] && return 0

    log "Installing cloudflared..."
    if ! command -v cloudflared &>/dev/null; then
        curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
            | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
        echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared focal main" \
            | sudo tee /etc/apt/sources.list.d/cloudflared.list
        sudo apt-get update -qq && sudo apt-get install -y cloudflared
    fi

    success "cloudflared installed"
    warn "Run 'cloudflared tunnel login' and configure tunnel for $CLOUDFLARE_DOMAIN"
    warn "See docs/wallet-access.md for full Cloudflare setup"
}

# ============================================================
# Send Telegram
# ============================================================
send_telegram() {
    [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ] && return 0
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TELEGRAM_CHAT_ID}" \
        -d parse_mode="HTML" \
        -d text="$1" > /dev/null 2>&1 || true
}

# ============================================================
# Print access info
# ============================================================
print_access_info() {
    local version="$1"
    echo ""
    echo -e "${GREEN}${BOLD}═══════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}${BOLD}  Canton Validator installed successfully!${NC}"
    echo -e "${GREEN}${BOLD}═══════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${BOLD}Network:${NC}      $NETWORK"
    echo -e "${BOLD}Version:${NC}      $version"
    echo -e "${BOLD}Party hint:${NC}   $PARTY_HINT"
    echo ""
    echo -e "${BOLD}Wallet access:${NC}"
    echo "  1. Open SSH tunnel:"
    echo "     ssh -L 8888:127.0.0.1:8888 $(whoami)@$(hostname -I | awk '{print $1}') -N"
    echo "  2. Open in browser: http://wallet.localhost:8888"
    echo "  3. Login: validator / <your password>"
    echo ""
    echo -e "${BOLD}Upgrade:${NC}"
    echo "  Manual : $TOOLKIT_DIR/scripts/setup.sh  (option 2)"
    echo "  Auto   : ${AUTO_UPGRADE:-false} (cron daily 22:00)"
    echo ""
    echo -e "${BOLD}Useful commands:${NC}"
    echo "  Health : $TOOLKIT_DIR/scripts/check_health.sh"
    echo "  Backup : $TOOLKIT_DIR/scripts/backup.sh"
    echo "  Wallet : $TOOLKIT_DIR/scripts/transfer.sh balance"
    echo ""
    echo -e "${BOLD}Logs:${NC}   $LOG_DIR/"
    echo -e "${BOLD}Config:${NC} $TOOLKIT_CONF"
    echo ""
}

# ============================================================
# Main
# ============================================================
check_deps
main_menu
