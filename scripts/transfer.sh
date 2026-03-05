#!/bin/bash
set -euo pipefail

# ============================================================
# Canton Validator Toolkit — transfer.sh
# CLI wallet: balance / send / history / offers
# ============================================================

CANTON_DIR="$HOME/.canton"
TOOLKIT_CONF="$CANTON_DIR/toolkit.conf"
WALLET_BASE="http://localhost:8888"
WALLET_HOST="wallet.localhost"

log()   { echo "[$(date '+%H:%M:%S')] $1"; }
error() { echo "[$(date '+%H:%M:%S')] ✗ $1" >&2; }
die()   { error "$1"; exit 1; }

# ============================================================
# Load config
# ============================================================
if [ ! -f "$TOOLKIT_CONF" ]; then
    die "toolkit.conf not found: $TOOLKIT_CONF — run setup.sh first"
fi
# shellcheck source=/dev/null
source "$TOOLKIT_CONF"

VERSION="${VERSION:-}"

# ============================================================
# Detect Canton version dir for get-token.py
# ============================================================
get_token_script() {
    local token_script=""

    # Try current symlink first
    if [ -L "$CANTON_DIR/current" ]; then
        token_script="$CANTON_DIR/current/splice-node/docker-compose/validator/get-token.py"
        [ -f "$token_script" ] && echo "$token_script" && return
    fi

    # Try VERSION from toolkit.conf
    if [ -n "$VERSION" ] && [ -f "$CANTON_DIR/$VERSION/splice-node/docker-compose/validator/get-token.py" ]; then
        echo "$CANTON_DIR/$VERSION/splice-node/docker-compose/validator/get-token.py"
        return
    fi

    # Fallback: find latest version dir (search up to depth 6 for non-standard layouts)
    token_script=$(find "$CANTON_DIR" -maxdepth 6 -name "get-token.py" 2>/dev/null \
        | sort -V | tail -1)
    [ -n "$token_script" ] && echo "$token_script" && return

    echo ""
}

# ============================================================
# Get JWT token
# ============================================================
get_token() {
    local script
    script=$(get_token_script)

    if [ -z "$script" ]; then
        die "get-token.py not found in ~/.canton/ — is Canton installed?"
    fi

    python3 "$script" administrator 2>/dev/null \
        || die "Failed to get JWT token from $script"
}

# ============================================================
# API call helper
# ============================================================
api_get() {
    local endpoint="$1"
    local token="$2"

    curl -s --fail-with-body \
        -H "Authorization: Bearer $token" \
        -H "Host: $WALLET_HOST" \
        -H "Content-Type: application/json" \
        "${WALLET_BASE}${endpoint}" 2>/dev/null || \
    curl -s \
        -H "Authorization: Bearer $token" \
        -H "Host: $WALLET_HOST" \
        -H "Content-Type: application/json" \
        "${WALLET_BASE}${endpoint}"
}

api_post() {
    local endpoint="$1"
    local token="$2"
    local body="$3"

    curl -s -X POST \
        -H "Authorization: Bearer $token" \
        -H "Host: $WALLET_HOST" \
        -H "Content-Type: application/json" \
        -d "$body" \
        "${WALLET_BASE}${endpoint}"
}

# ============================================================
# balance
# ============================================================
cmd_balance() {
    log "Getting wallet balance..."
    local token
    token=$(get_token)

    local result
    result=$(api_get "/api/validator/v0/wallet/balance" "$token") \
        || die "Cannot reach wallet API — is Canton running and port 8888 accessible?"

    local unlocked locked round
    unlocked=$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('effective_unlocked_qty','?'))" 2>/dev/null || echo "?")
    locked=$(echo "$result"   | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('effective_locked_qty','?'))" 2>/dev/null || echo "?")
    round=$(echo "$result"    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('round','?'))" 2>/dev/null || echo "?")

    echo ""
    echo "  Unlocked CC : $unlocked"
    echo "  Locked CC   : $locked"
    echo "  Round       : $round"
    echo ""
}

# ============================================================
# send
# ============================================================
cmd_send() {
    local to="" amount="" description="" tracking_id=""

    # Parse args
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --to)          to="$2";          shift 2 ;;
            --amount)      amount="$2";      shift 2 ;;
            --description) description="$2"; shift 2 ;;
            --tracking-id) tracking_id="$2"; shift 2 ;;
            *) die "Unknown argument: $1" ;;
        esac
    done

    [ -z "$to" ]     && die "--to is required (receiver party ID)"
    [ -z "$amount" ] && die "--amount is required"

    [ -z "$tracking_id" ] && tracking_id="toolkit-$(date +%s)"
    [ -z "$description" ] && description="Sent via canton-validator-toolkit"

    # expires_at in microseconds (now + 24h)
    local expires_at
    expires_at=$(python3 -c "import time; print(int((time.time() + 86400) * 1000000))")

    log "Sending $amount CC to $to ..."

    local token
    token=$(get_token)

    local body
    body=$(python3 -c "
import json, sys
print(json.dumps({
    'receiver_party_id': '$to',
    'amount': '$amount',
    'expires_at': $expires_at,
    'tracking_id': '$tracking_id',
    'description': '$description'
}))
")

    local result
    result=$(api_post "/api/validator/v0/wallet/transfer-offers" "$token" "$body") \
        || die "Transfer failed — check party ID and balance"

    local contract_id
    contract_id=$(echo "$result" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); print(d.get('offer_contract_id', d.get('transfer_offer_cid', d.get('contract_id','?'))))" \
        2>/dev/null || echo "?")

    echo ""
    echo "  Transfer offer created"
    echo "  Amount      : $amount CC"
    echo "  To          : $to"
    echo "  Tracking ID : $tracking_id"
    echo "  Contract ID : $contract_id"
    echo ""
}

# ============================================================
# history
# ============================================================
cmd_history() {
    local limit=10

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --limit) limit="$2"; shift 2 ;;
            *) die "Unknown argument: $1" ;;
        esac
    done
    log "Fetching last $limit transactions..."
    local token result
    token=$(get_token)
    result=$(api_post "/api/validator/v0/wallet/transactions" "$token" "{\"page_size\": $limit}")
    [ -z "$result" ] && die "Cannot fetch transactions — is Canton running?"
    echo ""
    echo "$result" | python3 -c "
import sys, json
data = json.loads(sys.stdin.read())
txs = data.get('items', []) if isinstance(data, dict) else []
if not txs:
    print('  No transactions found')
    sys.exit(0)
for tx in txs:
    tx_type  = tx.get('transaction_type', 'unknown')
    event_id = tx.get('event_id', '?')[:20]
    sender   = tx.get('sender') or {}
    amount   = sender.get('amount', '?') if isinstance(sender, dict) else '?'
    date_str = tx.get('date', '?')[:19].replace('T', ' ')
    print(f'  [{date_str}]  {tx_type:<35}  {str(amount):<14}  id:{event_id}...')
print()
"
}

# ============================================================
# offers
# ============================================================
cmd_offers() {
    log "Fetching pending transfer offers..."
    local token result
    token=$(get_token)
    result=$(api_get "/api/validator/v0/wallet/transfer-offers" "$token")
    [ -z "$result" ] && die "Cannot fetch transfer offers — is Canton running?"
    echo ""
    echo "$result" | python3 -c "
import sys, json
data = json.loads(sys.stdin.read())
offers = data.get('offers', data.get('transfer_offers', [])) if isinstance(data, dict) else []
if not offers:
    print('  No pending transfer offers')
    sys.exit(0)
for o in offers:
    payload  = o.get('payload', o)
    sender   = str(payload.get('sender', '?'))[:40]
    receiver = str(payload.get('receiver', '?'))[:40]
    amt      = payload.get('amount', {})
    amount   = amt.get('amount', '?') if isinstance(amt, dict) else str(amt)
    desc     = payload.get('description', '')
    cid      = o.get('contract_id', '?')[:20]
    print(f'  {amount} CC  {sender}... -> {receiver}...  \"{desc}\"  cid:{cid}...')
print()
"
}
# ============================================================
usage() {
    echo ""
    echo "Usage: transfer.sh <command> [options]"
    echo ""
    echo "Commands:"
    echo "  balance                          Show wallet balance"
    echo "  send --to <party> --amount <n>   Send CC"
    echo "       [--description <text>]"
    echo "       [--tracking-id <id>]"
    echo "  history [--limit <n>]            List recent transactions (default: 10)"
    echo "  offers                           List pending outgoing transfer offers"
    echo ""
    echo "Examples:"
    echo "  transfer.sh balance"
    echo "  transfer.sh send --to 'PARTY::1220...' --amount 10.0 --description 'payment'"
    echo "  transfer.sh history --limit 20"
    echo "  transfer.sh offers"
    echo ""
}

# ============================================================
# Main
# ============================================================
COMMAND="${1:-}"
shift || true

case "$COMMAND" in
    balance) cmd_balance ;;
    send)    cmd_send "$@" ;;
    history) cmd_history "$@" ;;
    offers)  cmd_offers ;;
    help|--help|-h|"") usage ;;
    *) error "Unknown command: $COMMAND"; usage; exit 1 ;;
esac
