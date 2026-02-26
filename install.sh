#!/bin/bash
set -euo pipefail

# ============================================================
# Canton Validator Toolkit — install.sh
# One-liner entrypoint:
#   curl -fsSL https://raw.githubusercontent.com/web3validator/canton-validator-toolkit/main/install.sh | bash
# ============================================================

REPO_URL="https://github.com/web3validator/canton-validator-toolkit"
TOOLKIT_DIR="$HOME/canton-validator-toolkit"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

log()     { echo -e "${GREEN}[canton]${NC} $1"; }
warn()    { echo -e "${YELLOW}[canton]${NC} $1"; }
error()   { echo -e "${RED}[canton]${NC} $1" >&2; }
die()     { error "$1"; exit 1; }

# ============================================================
# Dependency check
# ============================================================
check_deps() {
    log "Checking dependencies..."
    local missing=()

    for cmd in docker curl jq python3 openssl git; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done

    docker compose version &>/dev/null || missing+=("docker-compose-plugin")

    if [ ${#missing[@]} -gt 0 ]; then
        error "Missing: ${missing[*]}"
        echo ""
        echo "Install with:"
        echo "  sudo apt-get update && sudo apt-get install -y ${missing[*]}"
        echo ""
        echo "For docker compose plugin:"
        echo "  sudo apt-get install -y docker-compose-plugin"
        exit 1
    fi

    log "All dependencies OK"
}

# ============================================================
# Check OS
# ============================================================
check_os() {
    if [ "$(uname -s)" != "Linux" ]; then
        die "Only Linux is supported"
    fi

    if ! command -v apt-get &>/dev/null && ! command -v yum &>/dev/null; then
        warn "Non-debian/rpm system detected — proceeding anyway"
    fi
}

# ============================================================
# Download toolkit
# ============================================================
download_toolkit() {
    if [ -d "$TOOLKIT_DIR/.git" ]; then
        log "Toolkit already exists at $TOOLKIT_DIR — pulling latest..."
        cd "$TOOLKIT_DIR"
        git pull --ff-only 2>/dev/null || {
            warn "git pull failed (local changes?), using existing version"
        }
        return 0
    fi

    if [ -d "$TOOLKIT_DIR" ]; then
        warn "Directory $TOOLKIT_DIR exists but is not a git repo — removing..."
        rm -rf "$TOOLKIT_DIR"
    fi

    log "Cloning canton-validator-toolkit..."
    git clone --depth 1 "$REPO_URL" "$TOOLKIT_DIR" \
        || die "Failed to clone $REPO_URL"

    log "Toolkit downloaded to $TOOLKIT_DIR"
}

# ============================================================
# Make scripts executable
# ============================================================
set_permissions() {
    chmod +x "$TOOLKIT_DIR/scripts/"*.sh 2>/dev/null || true
    chmod +x "$TOOLKIT_DIR/install.sh" 2>/dev/null || true
}

# ============================================================
# Main
# ============================================================
main() {
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║   Canton Validator Toolkit — Installer       ║${NC}"
    echo -e "${BOLD}║   https://github.com/web3validator           ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
    echo ""

    check_os
    check_deps
    download_toolkit
    set_permissions

    log "Launching setup..."
    echo ""

    exec bash "$TOOLKIT_DIR/scripts/setup.sh"
}

main "$@"
