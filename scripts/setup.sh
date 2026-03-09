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
CYAN='\033[0;36m'
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
    if [ "$(uname -s)" != "Linux" ]; then
        die "Only Linux is supported"
    fi

    if ! command -v apt-get &>/dev/null; then
        die "Only Debian/Ubuntu (apt-get) systems are supported for auto-install"
    fi

    local apt_missing=()
    local need_docker=false

    for cmd in curl jq python3 openssl rsync git; do
        command -v "$cmd" &>/dev/null || apt_missing+=("$cmd")
    done

    if ! command -v docker &>/dev/null; then
        need_docker=true
    elif ! docker compose version &>/dev/null; then
        need_docker=true
    fi

    if [ ${#apt_missing[@]} -gt 0 ]; then
        log "Installing missing packages: ${apt_missing[*]}"
        sudo apt-get update -qq
        sudo apt-get install -y -qq "${apt_missing[@]}"
    fi

    if [ "$need_docker" = true ]; then
        log "Installing Docker via official repo..."
        sudo apt-get update -qq
        sudo apt-get install -y -qq ca-certificates curl gnupg lsb-release
        sudo install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
            | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        sudo chmod a+r /etc/apt/keyrings/docker.gpg
        echo \
            "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
            | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        sudo apt-get update -qq
        sudo apt-get install -y -qq \
            docker-ce docker-ce-cli containerd.io \
            docker-buildx-plugin docker-compose-plugin
        sudo usermod -aG docker "$USER" || true
        success "Docker installed"
    fi

    for cmd in docker curl jq python3 openssl rsync git; do
        command -v "$cmd" &>/dev/null || die "Dependency still missing after install: $cmd"
    done
    docker compose version &>/dev/null || die "docker compose plugin still not working after install"

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

get_validator_container() {
    docker ps -a --format '{{.Names}}' 2>/dev/null \
        | grep -E 'validator-1$' | grep -v postgres | head -1
}

get_our_version() {
    local c
    c=$(get_validator_container)
    [ -z "$c" ] && return 1
    docker inspect "$c" --format '{{.Config.Image}}' 2>/dev/null \
        | grep -oP ':\K[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

# ============================================================
# Detect existing validator installation (without toolkit.conf)
# ============================================================
detect_existing_validator() {
    # Running container
    local container
    container=$(docker ps --format '{{.Names}}' 2>/dev/null \
        | grep -E 'validator-1$' | grep -v postgres | head -1)
    [ -n "$container" ] && return 0

    # Bundle directory exists
    local bundle
    bundle=$(find "$HOME/.canton" -maxdepth 4 -name "compose.yaml" 2>/dev/null | head -1)
    [ -n "$bundle" ] && return 0

    return 1
}

# ============================================================
# Import config for existing validator (no reinstall)
# ============================================================
import_existing_config() {
    echo ""
    echo -e "${BOLD}─── Import Existing Validator Config ────────────${NC}"
    echo ""
    echo -e "  This will create ${BOLD}toolkit.conf${NC} for your running validator."
    echo -e "  ${GREEN}Nothing will be reinstalled or restarted.${NC}"
    echo ""

    # Try to auto-detect values from running containers / env files
    local detected_version="" detected_network="" detected_party="" detected_sv="" detected_scan="" detected_migration=""

    # Version from running container image (splice/canton images only, not nginx/postgres)
    detected_version=$(docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null \
        | grep -E 'validator-1' | grep -v 'nginx\|postgres' \
        | grep -oP ':\K[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)

    # Try to find .env in bundle — search deeper to catch ~/.canton/devnet/0.5.13/... structure
    local env_file=""
    env_file=$(find "$HOME/.canton" -maxdepth 7 -name ".env" 2>/dev/null \
        | grep -v 'current/' | sort -r | head -1 || true)
    if [ -n "$env_file" ]; then
        detected_party=$(grep     '^PARTY_HINT='         "$env_file" 2>/dev/null | cut -d= -f2 || true)
        detected_sv=$(grep        '^SPONSOR_SV_ADDRESS=' "$env_file" 2>/dev/null | cut -d= -f2 || true)
        detected_scan=$(grep      '^SCAN_ADDRESS='       "$env_file" 2>/dev/null | cut -d= -f2 || true)
        detected_migration=$(grep '^MIGRATION_ID='       "$env_file" 2>/dev/null | cut -d= -f2 || true)
    fi

    # Detect network — check SV URL, container names, and .canton bundle path
    local _net_hint=""

    # 1. From SV URL
    if echo "${detected_sv:-}" | grep -q '\.test\.'; then
        _net_hint="testnet"
    elif echo "${detected_sv:-}" | grep -q '\.dev\.'; then
        _net_hint="devnet"
    fi

    # 2. From running container names (e.g. splice-testnet-validator-1)
    if [ -z "$_net_hint" ]; then
        local _cnames
        _cnames=$(docker ps --format '{{.Names}}' 2>/dev/null || true)
        if echo "$_cnames" | grep -qi 'testnet'; then
            _net_hint="testnet"
        elif echo "$_cnames" | grep -qi 'devnet\|dev'; then
            _net_hint="devnet"
        fi
    fi

    # 3. From .canton bundle path (e.g. ~/.canton/0.5.13/splice-node/...)
    if [ -z "$_net_hint" ] && [ -n "$env_file" ]; then
        if echo "$env_file" | grep -qi 'testnet'; then
            _net_hint="testnet"
        elif echo "$env_file" | grep -qi 'devnet\|dev'; then
            _net_hint="devnet"
        fi
    fi

    # 4. From SCAN_ADDRESS in .env
    if [ -z "$_net_hint" ]; then
        if echo "${detected_scan:-}" | grep -q '\.test\.'; then
            _net_hint="testnet"
        elif echo "${detected_scan:-}" | grep -q '\.dev\.'; then
            _net_hint="devnet"
        fi
    fi

    detected_network="${_net_hint:-mainnet}"

    [ -n "$detected_version" ] && echo -e "  ${GREEN}Detected version  :${NC} $detected_version"
    [ -n "$detected_network" ] && echo -e "  ${GREEN}Detected network  :${NC} $detected_network"
    [ -n "$detected_party"   ] && echo -e "  ${GREEN}Detected party    :${NC} $detected_party"
    echo ""

    # Collect / confirm values
    echo -e "${BOLD}Select network:${NC}"
    echo "  1) mainnet"
    echo "  2) testnet"
    echo "  3) devnet"
    local net_choice
    read -rp "$(echo -e "${BOLD}Choice [1-3]${NC} [${detected_network:-mainnet}]: ")" net_choice
    case "$net_choice" in
        1) NETWORK="mainnet" ;;
        2) NETWORK="testnet" ;;
        3) NETWORK="devnet"  ;;
        "") NETWORK="${detected_network:-mainnet}" ;;
        *) NETWORK="${detected_network:-mainnet}" ;;
    esac

    # Set SV/Scan defaults by network if not detected from .env
    local default_sv default_scan default_migration
    case "$NETWORK" in
        testnet)
            default_sv="https://sv.sv-2.test.global.canton.network.digitalasset.com"
            default_scan="https://scan.sv-2.test.global.canton.network.digitalasset.com"
            default_migration="1"
            ;;
        devnet)
            default_sv="https://sv.sv-2.dev.global.canton.network.digitalasset.com"
            default_scan="https://scan.sv-2.dev.global.canton.network.digitalasset.com"
            default_migration="1"
            ;;
        *)
            default_sv="https://sv.sv-2.global.canton.network.digitalasset.com"
            default_scan="https://scan.sv-2.global.canton.network.digitalasset.com"
            default_migration="4"
            ;;
    esac

    prompt VERSION       "Canton version"    "${detected_version:-}"
    prompt PARTY_HINT    "Party hint"         "${detected_party:-}"
    prompt MIGRATION_ID  "Migration ID"       "${detected_migration:-$default_migration}"
    prompt SV_URL        "SV URL"             "${detected_sv:-$default_sv}"
    prompt SCAN_URL      "Scan URL"           "${detected_scan:-$default_scan}"
    prompt NODE_NAME     "Node name (for alerts)" "${PARTY_HINT}-${NETWORK}"

    # Backup
    BACKUP_TYPE="skip"
    REMOTE_HOST=""; REMOTE_PATH=""
    R2_BUCKET=""; R2_ACCOUNT_ID=""; R2_ACCESS_KEY=""; R2_SECRET_KEY=""
    RETENTION_DAYS="1"

    # Alert channels
    echo ""
    echo -e "${BOLD}Alert channels (all optional, configure later via Services → Health checks):${NC}"
    echo ""

    local tg_choice
    read -rp "$(echo -e "${BOLD}Configure Telegram? [y/N]${NC}: ")" tg_choice
    if [[ "$tg_choice" =~ ^[Yy]$ ]]; then
        prompt TELEGRAM_BOT_TOKEN "Bot token" ""
        prompt TELEGRAM_CHAT_ID   "Chat ID"   ""
    else
        TELEGRAM_BOT_TOKEN=""; TELEGRAM_CHAT_ID=""
    fi

    local dc_choice
    read -rp "$(echo -e "${BOLD}Configure Discord webhook? [y/N]${NC}: ")" dc_choice
    if [[ "$dc_choice" =~ ^[Yy]$ ]]; then
        prompt DISCORD_WEBHOOK_URL "Discord webhook URL" ""
    else
        DISCORD_WEBHOOK_URL=""
    fi

    local sl_choice
    read -rp "$(echo -e "${BOLD}Configure Slack webhook? [y/N]${NC}: ")" sl_choice
    if [[ "$sl_choice" =~ ^[Yy]$ ]]; then
        prompt SLACK_WEBHOOK_URL "Slack webhook URL" ""
    else
        SLACK_WEBHOOK_URL=""
    fi

    local pd_choice
    read -rp "$(echo -e "${BOLD}Configure PagerDuty? [y/N]${NC}: ")" pd_choice
    if [[ "$pd_choice" =~ ^[Yy]$ ]]; then
        prompt PAGERDUTY_ROUTING_KEY "Routing key" ""
    else
        PAGERDUTY_ROUTING_KEY=""
    fi

    AUTO_UPGRADE="false"
    MONITORING="false"
    CLOUDFLARE_TUNNEL="false"; CLOUDFLARE_DOMAIN=""
    TAILSCALE="false"; TAILSCALE_AUTHKEY=""
    ONBOARDING_SECRET=""
    CANTON_NETWORK_NAME="${CANTON_NETWORK_NAME:-splice-validator}"

    mkdir -p "$CANTON_DIR" "$LOG_DIR"
    save_toolkit_conf "${VERSION:-unknown}"

    echo ""
    success "toolkit.conf created — validator not touched"
    echo ""
    echo -e "  You can now use ${BOLD}Services${NC} to enable auto-upgrade, backup, health checks, monitoring."
    echo ""
    read -rp "$(echo -e "${BOLD}Press Enter to continue${NC}")"
    main_menu
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
    echo "  4) Services (auto-upgrade / backup / health / monitoring)"
    echo "  5) Advanced options"
    echo "  6) Exit"
    echo ""
    local choice
    read -rp "$(echo -e "${BOLD}Choice [1-6]${NC}: ")" choice

    case "$choice" in
        1) mode_install ;;
        2) mode_update ;;
        3) mode_status ;;
        4) mode_services ;;
        5) mode_advanced ;;
        6) exit 0 ;;
        *) die "Invalid choice" ;;
    esac
}

# ============================================================
# Mode: SERVICES
# ============================================================
mode_services() {
    if [ ! -f "$TOOLKIT_CONF" ]; then
        echo ""
        if detect_existing_validator; then
            echo -e "  ${YELLOW}⚠ toolkit.conf not found, but a validator installation was detected.${NC}"
            echo ""
            echo "  1) Create config for existing validator (no reinstall)"
            echo "  2) Back"
            echo ""
            local choice
            read -rp "$(echo -e "${BOLD}Choice [1-2]${NC}: ")" choice
            case "$choice" in
                1) import_existing_config; return ;;
                *) main_menu; return ;;
            esac
        else
            echo -e "  ${YELLOW}⚠ No validator installation found.${NC}"
            echo -e "  Run option ${BOLD}1) Install${NC} first."
            echo ""
            read -rp "$(echo -e "${BOLD}Press Enter to return${NC}")"
            main_menu
            return
        fi
    fi
    source "$TOOLKIT_CONF"

    while true; do
        # --- collect live statuses ---
        local au_status bu_status hc_status mon_status

        # auto-upgrade
        if crontab -l 2>/dev/null | grep -q "auto_upgrade.sh"; then
            au_status="${GREEN}enabled${NC}"
        else
            au_status="${RED}disabled${NC}"
        fi

        # backup
        if [ "${BACKUP_TYPE:-skip}" = "skip" ]; then
            bu_status="${RED}skip${NC}"
        elif crontab -l 2>/dev/null | grep -q "backup.sh"; then
            bu_status="${GREEN}${BACKUP_TYPE} (cron)${NC}"
        else
            bu_status="${YELLOW}${BACKUP_TYPE} (no cron)${NC}"
        fi

        # health check
        if crontab -l 2>/dev/null | grep -q "check_health.sh"; then
            hc_status="${GREEN}enabled${NC}"
        else
            hc_status="${RED}disabled${NC}"
        fi

        # monitoring
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "canton-grafana\|canton-prometheus"; then
            mon_status="${GREEN}running${NC}"
        else
            mon_status="${RED}stopped${NC}"
        fi

        echo ""
        echo -e "${BOLD}═══════════════════ Services ═══════════════════${NC}"
        echo ""
        echo -e "  1) Auto-upgrade    [ $(echo -e "$au_status") ]"
        echo -e "  2) Backup          [ $(echo -e "$bu_status") ]"
        echo -e "  3) Health checks   [ $(echo -e "$hc_status") ]"
        echo -e "  4) Monitoring      [ $(echo -e "$mon_status") ]"
        echo "  5) Back"
        echo ""
        local choice
        read -rp "$(echo -e "${BOLD}Choice [1-5]${NC}: ")" choice

        case "$choice" in
            1) _svc_autoupgrade ;;
            2) _svc_backup ;;
            3) _svc_health ;;
            4) _svc_monitoring ;;
            5) main_menu; return ;;
            *) warn "Invalid choice" ;;
        esac
    done
}

# ── auto-upgrade ─────────────────────────────────────────────
_svc_autoupgrade() {
    echo ""
    echo -e "${BOLD}─── Auto-upgrade ────────────────────────────────${NC}"
    echo ""
    if crontab -l 2>/dev/null | grep -q "auto_upgrade.sh"; then
        echo -e "  Status: ${GREEN}enabled${NC} (cron daily 22:00)"
        echo ""
        local choice
        read -rp "$(echo -e "${BOLD}Disable auto-upgrade? [y/N]${NC}: ")" choice
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            _cron_remove "auto_upgrade.sh"
            sed -i "s|^AUTO_UPGRADE=.*|AUTO_UPGRADE=false|" "$TOOLKIT_CONF"
            AUTO_UPGRADE="false"
            success "Auto-upgrade disabled"
        fi
    else
        echo -e "  Status: ${RED}disabled${NC}"
        echo ""
        local choice
        read -rp "$(echo -e "${BOLD}Enable auto-upgrade (cron daily 22:00)? [y/N]${NC}: ")" choice
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            _cron_add "0 22 * * * $TOOLKIT_DIR/scripts/auto_upgrade.sh >> $LOG_DIR/upgrade.log 2>&1" "auto_upgrade.sh"
            sed -i "s|^AUTO_UPGRADE=.*|AUTO_UPGRADE=true|" "$TOOLKIT_CONF"
            AUTO_UPGRADE="true"
            success "Auto-upgrade enabled (daily 22:00)"
        fi
    fi
}

# ── backup ───────────────────────────────────────────────────
_svc_backup() {
    echo ""
    echo -e "${BOLD}─── Backup ──────────────────────────────────────${NC}"
    echo ""
    echo -e "  Current type : ${BOLD}${BACKUP_TYPE:-skip}${NC}"
    if crontab -l 2>/dev/null | grep -q "backup.sh"; then
        echo -e "  Cron         : ${GREEN}every 4h${NC}"
    else
        echo -e "  Cron         : ${RED}not scheduled${NC}"
    fi
    echo ""
    echo "  1) Enable rsync backup"
    echo "  2) Enable Cloudflare R2 backup"
    echo "  3) Disable backup"
    echo "  4) Back"
    echo ""
    local choice
    read -rp "$(echo -e "${BOLD}Choice [1-4]${NC}: ")" choice

    case "$choice" in
        1)
            BACKUP_TYPE="rsync"
            echo ""
            echo -e "  ${YELLOW}Requirements:${NC}"
            echo -e "  • SSH key from this server must be added to the remote host"
            echo -e "  • Check: ${BOLD}cat ~/.ssh/id_rsa.pub${NC}  (or id_ed25519.pub)"
            echo -e "  • Add to remote: ${BOLD}ssh-copy-id user@host${NC}"
            echo ""
            prompt REMOTE_HOST "Remote host (user@host)" "${REMOTE_HOST:-}"
            # Test SSH connection before proceeding
            echo ""
            log "Testing SSH connection to $REMOTE_HOST ..."
            if ssh -o BatchMode=yes -o ConnectTimeout=10 "$REMOTE_HOST" "exit" 2>/dev/null; then
                success "SSH connection OK"
                # Expand ~ for remote path default
                local remote_user_hint
                remote_user_hint=$(echo "$REMOTE_HOST" | cut -d@ -f1)
                local raw_path
                prompt raw_path "Remote path (absolute)" "${REMOTE_PATH:-/home/${remote_user_hint}/canton-backups/${NETWORK:-mainnet}}"
                REMOTE_PATH="${raw_path/#\~//home/${remote_user_hint}}"
                # Create remote dir if missing
                log "Ensuring remote path exists: $REMOTE_PATH ..."
                if ssh -o BatchMode=yes -o ConnectTimeout=10 "$REMOTE_HOST" "mkdir -p '$REMOTE_PATH'" 2>/dev/null; then
                    success "Remote path ready: $REMOTE_HOST:$REMOTE_PATH"
                else
                    warn "Could not create remote path — check permissions on $REMOTE_HOST"
                fi
            else
                echo ""
                warn "Cannot connect to $REMOTE_HOST"
                echo ""
                echo -e "  ${BOLD}To fix:${NC}"
                echo -e "  1. Generate key if missing:  ${BOLD}ssh-keygen -t ed25519${NC}"
                echo -e "  2. Copy to remote:           ${BOLD}ssh-copy-id $REMOTE_HOST${NC}"
                echo -e "  3. Test manually:            ${BOLD}ssh $REMOTE_HOST${NC}"
                echo ""
                local ssh_choice
                read -rp "$(echo -e "${BOLD}Continue anyway? [y/N]${NC}: ")" ssh_choice
                [[ "$ssh_choice" =~ ^[Yy]$ ]] || return
                # SSH failed — still ask for path so config can be saved
                local raw_path_fail
                local remote_user_fail
                remote_user_fail=$(echo "$REMOTE_HOST" | cut -d@ -f1)
                prompt raw_path_fail "Remote path (absolute)" "${REMOTE_PATH:-/home/${remote_user_fail}/canton-backups/${NETWORK:-mainnet}}"
                REMOTE_PATH="${raw_path_fail/#\~//home/${remote_user_fail}}"
            fi
            R2_BUCKET=""; R2_ACCOUNT_ID=""; R2_ACCESS_KEY=""; R2_SECRET_KEY=""
            local ret_input
            prompt ret_input "Retention (days)" "${RETENTION_DAYS:-1}"
            [[ "$ret_input" =~ ^[0-9]+$ ]] && RETENTION_DAYS="$ret_input" || RETENTION_DAYS="1"
            _backup_save_conf
            _cron_add "0 */4 * * * $TOOLKIT_DIR/scripts/backup.sh >> $LOG_DIR/backup.log 2>&1" "backup.sh"
            success "rsync backup enabled (every 4h → $REMOTE_HOST:$REMOTE_PATH)"
            ;;
        2)
            BACKUP_TYPE="r2"
            prompt R2_BUCKET     "R2 bucket name"  "${R2_BUCKET:-}"
            prompt R2_ACCOUNT_ID "R2 account ID"   "${R2_ACCOUNT_ID:-}"
            prompt R2_ACCESS_KEY "R2 access key"   "${R2_ACCESS_KEY:-}"
            prompt_secret R2_SECRET_KEY "R2 secret key"
            REMOTE_HOST=""; REMOTE_PATH=""
            local ret_input
            prompt ret_input "Retention (days)" "${RETENTION_DAYS:-1}"
            [[ "$ret_input" =~ ^[0-9]+$ ]] && RETENTION_DAYS="$ret_input" || RETENTION_DAYS="1"
            _backup_save_conf
            _cron_add "0 */4 * * * $TOOLKIT_DIR/scripts/backup.sh >> $LOG_DIR/backup.log 2>&1" "backup.sh"
            success "R2 backup enabled (every 4h)"
            ;;
        3)
            _cron_remove "backup.sh"
            BACKUP_TYPE="skip"
            sed -i "s|^BACKUP_TYPE=.*|BACKUP_TYPE=skip|" "$TOOLKIT_CONF"
            success "Backup disabled"
            ;;
        4) return ;;
    esac
}

_backup_save_conf() {
    sed -i "s|^BACKUP_TYPE=.*|BACKUP_TYPE=${BACKUP_TYPE}|"         "$TOOLKIT_CONF"
    sed -i "s|^REMOTE_HOST=.*|REMOTE_HOST=${REMOTE_HOST:-}|"       "$TOOLKIT_CONF"
    sed -i "s|^REMOTE_PATH=.*|REMOTE_PATH=${REMOTE_PATH:-}|"       "$TOOLKIT_CONF"
    sed -i "s|^R2_BUCKET=.*|R2_BUCKET=${R2_BUCKET:-}|"             "$TOOLKIT_CONF"
    sed -i "s|^R2_ACCOUNT_ID=.*|R2_ACCOUNT_ID=${R2_ACCOUNT_ID:-}|" "$TOOLKIT_CONF"
    sed -i "s|^R2_ACCESS_KEY=.*|R2_ACCESS_KEY=${R2_ACCESS_KEY:-}|" "$TOOLKIT_CONF"
    sed -i "s|^R2_SECRET_KEY=.*|R2_SECRET_KEY=${R2_SECRET_KEY:-}|" "$TOOLKIT_CONF"
    sed -i "s|^RETENTION_DAYS=.*|RETENTION_DAYS=${RETENTION_DAYS}|" "$TOOLKIT_CONF"
}

# ── health checks ────────────────────────────────────────────
_svc_health() {
    echo ""
    echo -e "${BOLD}─── Health Checks ───────────────────────────────${NC}"
    echo ""

    # Show alert channels status
    local any_alerts=false
    [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ] \
        && echo -e "  Telegram  : ${GREEN}configured${NC}" && any_alerts=true \
        || echo -e "  Telegram  : ${YELLOW}not configured${NC}"
    [ -n "${DISCORD_WEBHOOK_URL:-}" ] \
        && echo -e "  Discord   : ${GREEN}configured${NC}" && any_alerts=true \
        || echo -e "  Discord   : ${YELLOW}not configured${NC}"
    [ -n "${SLACK_WEBHOOK_URL:-}" ] \
        && echo -e "  Slack     : ${GREEN}configured${NC}" && any_alerts=true \
        || echo -e "  Slack     : ${YELLOW}not configured${NC}"
    [ -n "${PAGERDUTY_ROUTING_KEY:-}" ] \
        && echo -e "  PagerDuty : ${GREEN}configured${NC}" && any_alerts=true \
        || echo -e "  PagerDuty : ${YELLOW}not configured${NC}"
    if [ "$any_alerts" = false ]; then
        echo ""
        warn "No alert channels configured — alerts go to log only: $LOG_DIR/health.log"
    fi
    echo ""

    if crontab -l 2>/dev/null | grep -q "check_health.sh"; then
        echo -e "  Status: ${GREEN}enabled${NC} (cron every 15 min)"
        echo ""
        echo "  1) Disable health checks"
        echo "  2) Configure alert channels"
        echo "  3) Back"
        echo ""
        local choice
        read -rp "$(echo -e "${BOLD}Choice [1-3]${NC}: ")" choice
        case "$choice" in
            1)
                _cron_remove "check_health.sh"
                success "Health checks disabled"
                ;;
            2) _svc_health_alerts ;;
            3) return ;;
        esac
    else
        echo -e "  Status: ${RED}disabled${NC}"
        echo ""
        echo "  1) Enable health checks (every 15 min)"
        echo "  2) Configure alert channels"
        echo "  3) Back"
        echo ""
        local choice
        read -rp "$(echo -e "${BOLD}Choice [1-3]${NC}: ")" choice
        case "$choice" in
            1)
                _cron_add "*/15 * * * * $TOOLKIT_DIR/scripts/check_health.sh >> $LOG_DIR/health.log 2>&1" "check_health.sh"
                success "Health checks enabled (every 15 min)"
                if [ "$any_alerts" = false ]; then
                    echo ""
                    warn "No alert channels configured — alerts will only appear in $LOG_DIR/health.log"
                    echo -e "  Configure via option 2 in this menu"
                fi
                ;;
            2) _svc_health_alerts ;;
            3) return ;;
        esac
    fi
}

_svc_health_alerts() {
    while true; do
        source "$TOOLKIT_CONF"
        echo ""
        echo -e "${BOLD}─── Alert Channels ──────────────────────────────${NC}"
        echo ""
        local tg_st dc_st sl_st pd_st
        [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ] \
            && tg_st="${GREEN}configured${NC}" || tg_st="${YELLOW}not set${NC}"
        [ -n "${DISCORD_WEBHOOK_URL:-}" ] \
            && dc_st="${GREEN}configured${NC}" || dc_st="${YELLOW}not set${NC}"
        [ -n "${SLACK_WEBHOOK_URL:-}" ] \
            && sl_st="${GREEN}configured${NC}" || sl_st="${YELLOW}not set${NC}"
        [ -n "${PAGERDUTY_ROUTING_KEY:-}" ] \
            && pd_st="${GREEN}configured${NC}" || pd_st="${YELLOW}not set${NC}"

        echo -e "  1) Telegram   [ $(echo -e "$tg_st") ]"
        echo -e "  2) Discord    [ $(echo -e "$dc_st") ]"
        echo -e "  3) Slack      [ $(echo -e "$sl_st") ]"
        echo -e "  4) PagerDuty  [ $(echo -e "$pd_st") ]"
        echo "  5) Back"
        echo ""
        local choice
        read -rp "$(echo -e "${BOLD}Choice [1-5]${NC}: ")" choice
        case "$choice" in
            1) _alert_configure_telegram ;;
            2) _alert_configure_discord ;;
            3) _alert_configure_slack ;;
            4) _alert_configure_pagerduty ;;
            5) return ;;
            *) warn "Invalid choice" ;;
        esac
    done
}

_alert_configure_telegram() {
    echo ""
    echo -e "${BOLD}─── Telegram ────────────────────────────────────${NC}"
    echo ""
    [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && echo -e "  Token  : ${BOLD}${TELEGRAM_BOT_TOKEN:0:10}...${NC}"
    [ -n "${TELEGRAM_CHAT_ID:-}" ]   && echo -e "  Chat ID: ${BOLD}${TELEGRAM_CHAT_ID}${NC}"
    echo ""
    echo -e "  Create bot : ${BLUE}https://t.me/BotFather${NC}"
    echo -e "  Get chat ID: curl https://api.telegram.org/bot<TOKEN>/getUpdates"
    echo ""
    echo "  1) Configure"
    echo "  2) Disable (clear)"
    echo "  3) Back"
    echo ""
    local choice
    read -rp "$(echo -e "${BOLD}Choice [1-3]${NC}: ")" choice
    case "$choice" in
        1)
            local token chat_id
            prompt token   "Bot token"  "${TELEGRAM_BOT_TOKEN:-}"
            prompt chat_id "Chat ID"    "${TELEGRAM_CHAT_ID:-}"
            if [ -n "$token" ] && [ -n "$chat_id" ]; then
                sed -i "s|^TELEGRAM_BOT_TOKEN=.*|TELEGRAM_BOT_TOKEN=${token}|"  "$TOOLKIT_CONF"
                sed -i "s|^TELEGRAM_CHAT_ID=.*|TELEGRAM_CHAT_ID=${chat_id}|"    "$TOOLKIT_CONF"
                TELEGRAM_BOT_TOKEN="$token"; TELEGRAM_CHAT_ID="$chat_id"
                local resp
                resp=$(curl -s -X POST "https://api.telegram.org/bot${token}/sendMessage" \
                    -d chat_id="${chat_id}" -d parse_mode="HTML" \
                    -d text="✅ <b>${NODE_NAME:-Canton Validator}</b> — Telegram alerts configured" 2>/dev/null)
                echo "$resp" | grep -q '"ok":true' \
                    && success "Telegram configured + test message sent" \
                    || warn "Saved but test message failed — check token/chat ID"
            fi
            ;;
        2)
            sed -i "s|^TELEGRAM_BOT_TOKEN=.*|TELEGRAM_BOT_TOKEN=|" "$TOOLKIT_CONF"
            sed -i "s|^TELEGRAM_CHAT_ID=.*|TELEGRAM_CHAT_ID=|"     "$TOOLKIT_CONF"
            TELEGRAM_BOT_TOKEN=""; TELEGRAM_CHAT_ID=""
            success "Telegram alerts disabled"
            ;;
        3) return ;;
    esac
}

_alert_configure_discord() {
    echo ""
    echo -e "${BOLD}─── Discord ─────────────────────────────────────${NC}"
    echo ""
    [ -n "${DISCORD_WEBHOOK_URL:-}" ] && echo -e "  Webhook: ${BOLD}${DISCORD_WEBHOOK_URL:0:40}...${NC}"
    echo ""
    echo -e "  Get webhook: Discord channel → Edit → Integrations → Webhooks"
    echo ""
    echo "  1) Configure"
    echo "  2) Disable (clear)"
    echo "  3) Back"
    echo ""
    local choice
    read -rp "$(echo -e "${BOLD}Choice [1-3]${NC}: ")" choice
    case "$choice" in
        1)
            local url
            prompt url "Webhook URL" "${DISCORD_WEBHOOK_URL:-}"
            if [ -n "$url" ]; then
                sed -i "s|^DISCORD_WEBHOOK_URL=.*|DISCORD_WEBHOOK_URL=${url}|" "$TOOLKIT_CONF"
                DISCORD_WEBHOOK_URL="$url"
                local resp
                resp=$(curl -s -X POST "$url" -H "Content-Type: application/json" \
                    -d "{\"content\": \"✅ **${NODE_NAME:-Canton Validator}** — Discord alerts configured\"}" 2>/dev/null)
                echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if d.get('id') or d == {} else 1)" 2>/dev/null \
                    && success "Discord configured + test message sent" \
                    || warn "Saved but test message failed — check webhook URL"
            fi
            ;;
        2)
            sed -i "s|^DISCORD_WEBHOOK_URL=.*|DISCORD_WEBHOOK_URL=|" "$TOOLKIT_CONF"
            DISCORD_WEBHOOK_URL=""
            success "Discord alerts disabled"
            ;;
        3) return ;;
    esac
}

_alert_configure_slack() {
    echo ""
    echo -e "${BOLD}─── Slack ───────────────────────────────────────${NC}"
    echo ""
    [ -n "${SLACK_WEBHOOK_URL:-}" ] && echo -e "  Webhook: ${BOLD}${SLACK_WEBHOOK_URL:0:40}...${NC}"
    echo ""
    echo -e "  Get webhook: ${BLUE}https://api.slack.com/apps${NC} → Incoming Webhooks"
    echo ""
    echo "  1) Configure"
    echo "  2) Disable (clear)"
    echo "  3) Back"
    echo ""
    local choice
    read -rp "$(echo -e "${BOLD}Choice [1-3]${NC}: ")" choice
    case "$choice" in
        1)
            local url
            prompt url "Webhook URL" "${SLACK_WEBHOOK_URL:-}"
            if [ -n "$url" ]; then
                sed -i "s|^SLACK_WEBHOOK_URL=.*|SLACK_WEBHOOK_URL=${url}|" "$TOOLKIT_CONF"
                SLACK_WEBHOOK_URL="$url"
                local resp
                resp=$(curl -s -X POST "$url" -H "Content-Type: application/json" \
                    -d "{\"text\": \"✅ *${NODE_NAME:-Canton Validator}* — Slack alerts configured\"}" 2>/dev/null)
                [ "$resp" = "ok" ] \
                    && success "Slack configured + test message sent" \
                    || warn "Saved but test message failed — check webhook URL"
            fi
            ;;
        2)
            sed -i "s|^SLACK_WEBHOOK_URL=.*|SLACK_WEBHOOK_URL=|" "$TOOLKIT_CONF"
            SLACK_WEBHOOK_URL=""
            success "Slack alerts disabled"
            ;;
        3) return ;;
    esac
}

_alert_configure_pagerduty() {
    echo ""
    echo -e "${BOLD}─── PagerDuty ───────────────────────────────────${NC}"
    echo ""
    [ -n "${PAGERDUTY_ROUTING_KEY:-}" ] && echo -e "  Routing key: ${BOLD}${PAGERDUTY_ROUTING_KEY:0:10}...${NC}"
    echo ""
    echo -e "  Get key: PagerDuty → Services → Integrations → Events API v2"
    echo -e "  ${BLUE}https://support.pagerduty.com/docs/services-and-integrations${NC}"
    echo ""
    echo "  1) Configure"
    echo "  2) Disable (clear)"
    echo "  3) Back"
    echo ""
    local choice
    read -rp "$(echo -e "${BOLD}Choice [1-3]${NC}: ")" choice
    case "$choice" in
        1)
            local key
            prompt key "Routing key" "${PAGERDUTY_ROUTING_KEY:-}"
            if [ -n "$key" ]; then
                sed -i "s|^PAGERDUTY_ROUTING_KEY=.*|PAGERDUTY_ROUTING_KEY=${key}|" "$TOOLKIT_CONF"
                PAGERDUTY_ROUTING_KEY="$key"
                local resp
                resp=$(curl -s -X POST "https://events.pagerduty.com/v2/enqueue" \
                    -H "Content-Type: application/json" \
                    -d "{\"routing_key\":\"${key}\",\"event_action\":\"trigger\",\"dedup_key\":\"canton-test-$(hostname)\",\"payload\":{\"summary\":\"Canton Validator — PagerDuty alerts configured\",\"source\":\"$(hostname)\",\"severity\":\"info\"}}" 2>/dev/null)
                echo "$resp" | grep -q '"status":"success"' \
                    && success "PagerDuty configured + test event sent" \
                    || warn "Saved but test event failed — check routing key"
            fi
            ;;
        2)
            sed -i "s|^PAGERDUTY_ROUTING_KEY=.*|PAGERDUTY_ROUTING_KEY=|" "$TOOLKIT_CONF"
            PAGERDUTY_ROUTING_KEY=""
            success "PagerDuty alerts disabled"
            ;;
        3) return ;;
    esac
}

# ── monitoring ───────────────────────────────────────────────
_svc_monitoring() {
    source "$TOOLKIT_CONF"
    echo ""
    echo -e "${BOLD}─── Monitoring ──────────────────────────────────${NC}"
    echo ""

    local running=false
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "canton-grafana\|canton-prometheus" && running=true

    # Detect compose working dir and project from running container labels
    _mon_compose_dir() {
        docker inspect canton-grafana \
            --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null || echo "$TOOLKIT_DIR/monitoring"
    }
    _mon_compose_project() {
        docker inspect canton-grafana \
            --format '{{index .Config.Labels "com.docker.compose.project"}}' 2>/dev/null || echo "monitoring"
    }

    if [ "$running" = "true" ]; then
        local mon_dir mon_project
        mon_dir=$(_mon_compose_dir)
        mon_project=$(_mon_compose_project)
        echo -e "  Status:  ${GREEN}running${NC}"
        echo -e "  Grafana: http://localhost:3001"
        if [ -n "${TAILSCALE_IP:-}" ]; then
            echo -e "  Tailscale: http://${TAILSCALE_IP}:3001"
        else
            local _server_ip
            # Prefer SSH_CONNECTION (real client-facing IP), fallback to public IP
            _server_ip=$(echo "${SSH_CONNECTION:-}" | awk '{print $3}')
            if [ -z "$_server_ip" ]; then
                _server_ip=$(curl -sf --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
            fi
            echo -e "  SSH tunnel: ${BOLD}ssh -L 3001:localhost:3001 $(whoami)@${_server_ip} -N${NC}"
            echo -e "  Then open: http://localhost:3001"
        fi
        echo ""
        echo "  1) Stop monitoring"
        echo "  2) Restart monitoring"
        echo "  3) Back"
        echo ""
        local choice
        read -rp "$(echo -e "${BOLD}Choice [1-3]${NC}: ")" choice
        case "$choice" in
            1)
                cd "$mon_dir"
                CANTON_NETWORK_NAME="${CANTON_NETWORK_NAME:-splice-validator}" \
                    docker compose -p "$mon_project" down
                sed -i "s|^MONITORING=.*|MONITORING=false|" "$TOOLKIT_CONF"
                success "Monitoring stopped"
                ;;
            2)
                cd "$mon_dir"
                CANTON_NETWORK_NAME="${CANTON_NETWORK_NAME:-splice-validator}" \
                    docker compose -p "$mon_project" restart
                success "Monitoring restarted"
                ;;
            3) return ;;
        esac
    else
        echo -e "  Status: ${RED}stopped${NC}"
        echo ""
        echo "  1) Start monitoring"
        echo "  2) Start + configure Tailscale"
        echo "  3) Back"
        echo ""
        local choice
        read -rp "$(echo -e "${BOLD}Choice [1-3]${NC}: ")" choice
        case "$choice" in
            1)
                MONITORING="true"
                install_monitoring
                sed -i "s|^MONITORING=.*|MONITORING=true|" "$TOOLKIT_CONF"
                ;;
            2)
                MONITORING="true"
                TAILSCALE="true"
                echo ""
                echo -e "  Get auth key: ${BLUE}https://login.tailscale.com/admin/settings/keys${NC}"
                prompt TAILSCALE_AUTHKEY "Auth key (tskey-auth-..., or empty for browser auth)" "${TAILSCALE_AUTHKEY:-}"
                install_monitoring
                install_tailscale
                sed -i "s|^MONITORING=.*|MONITORING=true|" "$TOOLKIT_CONF"
                sed -i "s|^TAILSCALE=.*|TAILSCALE=true|"   "$TOOLKIT_CONF"
                ;;
            3) return ;;
        esac
    fi
}

# ── cron helpers ─────────────────────────────────────────────
_cron_add() {
    local line="$1"
    local tag="$2"
    local tmpfile
    tmpfile=$(mktemp)
    crontab -l 2>/dev/null | grep -v "$tag" > "$tmpfile" || true
    echo "$line" >> "$tmpfile"
    crontab "$tmpfile"
    rm -f "$tmpfile"
}

_cron_remove() {
    local tag="$1"
    local tmpfile
    tmpfile=$(mktemp)
    crontab -l 2>/dev/null | grep -v "$tag" > "$tmpfile" || true
    crontab "$tmpfile"
    rm -f "$tmpfile"
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
    local has_unhealthy=false
    local _vc _pc _nc
    _vc=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E 'validator-1$'   | grep -v postgres | head -1)
    _pc=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E 'participant-1$'  | head -1)
    _nc=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E 'nginx-1$'        | head -1)
    for c in ${_vc:-splice-validator-validator-1} ${_pc:-splice-validator-participant-1} ${_nc:-splice-validator-nginx-1}; do
        local running health
        running=$(docker inspect --format='{{.State.Running}}' "$c" 2>/dev/null || echo "false")
        health=$(docker inspect --format='{{.State.Health.Status}}' "$c" 2>/dev/null || echo "n/a")
        if [ "$running" = "true" ]; then
            if [ "$health" = "healthy" ]; then
                echo -e "    ${GREEN}●${NC} $c [$health]  ${GREEN}✓${NC}"
            elif [ "$health" = "unhealthy" ]; then
                echo -e "    ${YELLOW}●${NC} $c [$health]  ${YELLOW}⚠${NC}"
                has_unhealthy=true
            else
                echo -e "    ${GREEN}●${NC} $c [$health]"
            fi
        else
            echo -e "    ${RED}●${NC} $c [down]"
        fi
    done
    echo ""

    if [ "$has_unhealthy" = "true" ]; then
        echo -e "  ${YELLOW}⚠ WARNING: One or more containers are unhealthy!${NC}"
        echo -e "  Check logs: ${BOLD}docker logs ${_vc:-splice-validator-validator-1}${NC}"
        echo ""
    fi

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
# Mode: ADVANCED
# ============================================================
mode_advanced() {
    echo ""
    echo -e "${BOLD}═══════════════════ Advanced Options ═══════════════════${NC}"
    echo ""
    echo -e "  ${BOLD}Canton Network Indexer${NC}"
    echo -e "  Unified REST API for Canton Network — historical rewards,"
    echo -e "  prices, validator uptime, leaderboard and more."
    echo ""
    echo -e "  ${CYAN}https://github.com/web3validator/canton-network-indexer${NC}"
    echo ""
    echo -e "  Quick deploy (mainnet + testnet + devnet):"
    echo -e "  ${BOLD}bash deploy_indexer.sh -h <server> -u <user> -n mainnet,testnet,devnet${NC}"
    echo ""
    echo -e "  Live API:"
    echo -e "  • MainNet: ${CYAN}https://canton-indexer.web34ever.com${NC}"
    echo -e "  • TestNet: ${CYAN}https://canton-indexer.web34ever.com/testnet/${NC}"
    echo -e "  • DevNet:  ${CYAN}https://canton-indexer.web34ever.com/devnet/${NC}"
    echo ""
    read -rp "$(echo -e "${BOLD}Press Enter to return to main menu${NC}")"
    main
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
    local _existing_vc
    _existing_vc=$(get_validator_container)
    if [ -n "$_existing_vc" ]; then
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
    DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
    SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
    PAGERDUTY_ROUTING_KEY="${PAGERDUTY_ROUTING_KEY:-}"

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

    # 13. Monitoring remote access
    TAILSCALE="false"
    TAILSCALE_AUTHKEY=""
    if [ "$MONITORING" = "true" ]; then
        echo ""
        echo -e "${BOLD}Grafana remote access:${NC}"
        echo "  1) SSH tunnel only (default)"
        echo "  2) Tailscale (no domain needed, recommended)"
        echo "  3) Skip"
        local access_choice
        read -rp "$(echo -e "${BOLD}Choice [1-3]${NC}: ")" access_choice
        if [ "$access_choice" = "2" ]; then
            TAILSCALE="true"
            echo ""
            echo -e "  Get auth key: ${BLUE}https://login.tailscale.com/admin/settings/keys${NC}"
            prompt TAILSCALE_AUTHKEY "Auth key (tskey-auth-..., or empty for browser auth)" ""
        fi
    fi

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
    echo "  Tailscale:    $TAILSCALE"
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
    install_tailscale
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
        local _wvc
        _wvc=$(get_validator_container)
        status=$(docker inspect --format='{{.State.Health.Status}}' \
            "${_wvc:-splice-validator-validator-1}" 2>/dev/null || echo "not_found")
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
# Patch compose.yaml (port 80 → 8888, localhost-only bind)
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

# ── Validator ─────────────────────────────────
NETWORK=${NETWORK}
VERSION=${version}
PARTY_HINT=${PARTY_HINT}
MIGRATION_ID=${MIGRATION_ID}
SV_URL=${SV_URL}
SCAN_URL=${SCAN_URL}
NODE_NAME=${NODE_NAME}
CANTON_NETWORK_NAME=${CANTON_NETWORK_NAME:-splice-validator}

# ── Backup ────────────────────────────────────
BACKUP_TYPE=${BACKUP_TYPE}
REMOTE_HOST=${REMOTE_HOST:-}
REMOTE_PATH=${REMOTE_PATH:-}
R2_BUCKET=${R2_BUCKET:-}
R2_ACCOUNT_ID=${R2_ACCOUNT_ID:-}
R2_ACCESS_KEY=${R2_ACCESS_KEY:-}
R2_SECRET_KEY=${R2_SECRET_KEY:-}
RETENTION_DAYS=${RETENTION_DAYS}

# ── Alerts ────────────────────────────────────
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN:-}
TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID:-}
DISCORD_WEBHOOK_URL=${DISCORD_WEBHOOK_URL:-}
SLACK_WEBHOOK_URL=${SLACK_WEBHOOK_URL:-}
PAGERDUTY_ROUTING_KEY=${PAGERDUTY_ROUTING_KEY:-}

# ── Services & Monitoring ─────────────────────
AUTO_UPGRADE=${AUTO_UPGRADE:-false}
WAIT_HOURS=12
MONITORING=${MONITORING}
TAILSCALE=${TAILSCALE:-false}
TAILSCALE_AUTHKEY=${TAILSCALE_AUTHKEY:-}
TAILSCALE_IP=${TAILSCALE_IP:-}

# ── Internal ──────────────────────────────────
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
        local _wvc2
        _wvc2=$(get_validator_container)
        status=$(docker inspect --format='{{.State.Health.Status}}' \
            "${_wvc2:-splice-validator-validator-1}" 2>/dev/null || echo "not_found")
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
    success "Monitoring started — Grafana: http://localhost:3001 (admin/admin)"
}
# ============================================================
# Install Tailscale
# ============================================================
install_tailscale() {
    [ "${TAILSCALE:-false}" != "true" ] && return 0

    log "Installing Tailscale..."
    if ! command -v tailscale &>/dev/null; then
        curl -fsSL https://tailscale.com/install.sh | sh >/dev/null 2>&1 || {
            warn "Tailscale install failed — install manually: curl -fsSL https://tailscale.com/install.sh | sh"
            return 0
        }
    fi
    success "Tailscale installed"

    local ts_ip=""
    if [ -n "${TAILSCALE_AUTHKEY:-}" ]; then
        log "Connecting to Tailscale with auth key..."
        sudo tailscale up --authkey="$TAILSCALE_AUTHKEY" --accept-routes >/dev/null 2>&1 && {
            sleep 3
            ts_ip=$(tailscale ip -4 2>/dev/null || echo "")
            [ -n "$ts_ip" ] && success "Tailscale connected: $ts_ip"
        } || warn "tailscale up failed — run manually: sudo tailscale up"
    else
        log "Starting Tailscale — browser authorization required..."
        local auth_url
        auth_url=$(sudo tailscale up --accept-routes 2>&1 | grep -oP 'https://login\.tailscale\.com/\S+' | head -1 || echo "")
        echo ""
        if [ -n "$auth_url" ]; then
            echo -e "  ${BOLD}Authorize Tailscale in your browser:${NC}"
            echo -e "  ${BLUE}${auth_url}${NC}"
        else
            echo -e "  ${BOLD}Run:${NC} sudo tailscale up"
            echo -e "  Then open the URL shown in your browser."
        fi
        echo ""
        echo -e "  After authorization: ${BOLD}http://<tailscale-ip>:3001${NC}"
        echo -e "  Get your Tailscale IP: tailscale ip -4"
        warn "Complete browser auth to access Grafana via Tailscale"
        return 0
    fi

    if [ -n "$ts_ip" ]; then
        echo ""
        echo -e "  ${GREEN}${BOLD}Grafana via Tailscale:${NC}  http://${ts_ip}:3001"
        echo -e "  Install Tailscale on your device: ${BLUE}https://tailscale.com/download${NC}"
        grep -q "^TAILSCALE_IP=" "$TOOLKIT_CONF" 2>/dev/null \
            && sed -i "s|^TAILSCALE_IP=.*|TAILSCALE_IP=${ts_ip}|" "$TOOLKIT_CONF" \
            || echo "TAILSCALE_IP=${ts_ip}" >> "$TOOLKIT_CONF"

        # Restart monitoring bound to Tailscale IP so it's reachable remotely
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "canton-grafana"; then
            log "Restarting monitoring with MONITOR_BIND_IP=${ts_ip}..."
            local mon_dir
            mon_dir=$(docker inspect canton-grafana \
                --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null \
                || echo "$TOOLKIT_DIR/monitoring")
            local mon_project
            mon_project=$(docker inspect canton-grafana \
                --format '{{index .Config.Labels "com.docker.compose.project"}}' 2>/dev/null \
                || echo "monitoring")
            cd "$mon_dir"
            MONITOR_BIND_IP="$ts_ip" \
            CANTON_NETWORK_NAME="${CANTON_NETWORK_NAME:-splice-validator}" \
                docker compose -p "$mon_project" up -d --force-recreate grafana prometheus node-exporter \
                2>/dev/null || true
            success "Monitoring restarted on ${ts_ip}:3001"
        fi
    fi
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
    echo "     ssh -L 8888:localhost:8888 $(whoami)@$(hostname -I | awk '{print $1}') -N"
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
