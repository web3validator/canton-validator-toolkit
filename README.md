# Canton Validator Toolkit

Production toolkit for Canton Network validators — automated install, upgrades, backups, and monitoring. Built from real validator operations on MainNet, TestNet, and DevNet.

```bash
curl -fsSL https://raw.githubusercontent.com/web3validator/canton-validator-toolkit/main/install.sh | bash
```

---

## What's inside

| Script | What it does |
|--------|-------------|
| `scripts/setup.sh` | Interactive menu: install / update / status |
| `scripts/auto_upgrade.sh` | Cron-based auto-upgrader (disabled by default) |
| `scripts/backup.sh` | PostgreSQL dump → rsync or Cloudflare R2 |
| `scripts/check_health.sh` | Health check + Telegram alerts (no spam) |
| `scripts/transfer.sh` | CLI wallet: balance / send CC / history |
| `monitoring/` | Prometheus + Grafana + node-exporter stack |

---

## Requirements

- Ubuntu 20.04+ (tested), Debian works too
- Docker + Docker Compose plugin v2
- `curl`, `jq`, `python3`, `openssl`, `rsync`
- Outbound internet access (GitHub, Canton network APIs)

```bash
sudo apt-get update && sudo apt-get install -y \
  docker.io docker-compose-plugin \
  curl jq python3 openssl rsync
```

---

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/web3validator/canton-validator-toolkit/main/install.sh | bash
```

Or manually:

```bash
git clone https://github.com/web3validator/canton-validator-toolkit ~/canton-validator-toolkit
chmod +x ~/canton-validator-toolkit/scripts/*.sh
~/canton-validator-toolkit/scripts/setup.sh
```

The installer will ask you:

1. Network (mainnet / testnet / devnet)
2. Party hint — your validator name, e.g. `MyOrg-validator-1`
3. Migration ID (4 for mainnet, 1 for testnet/devnet)
4. SV sponsor URL + Scan URL (defaults provided)
5. Onboarding secret (leave empty if already onboarded)
6. Wallet password (nginx basic auth, username: `validator`)
7. Backup target: rsync / Cloudflare R2 / skip
8. Telegram alerts (bot token + chat ID)
9. Auto-upgrade: yes/no (default: **no**)
10. Grafana monitoring stack: yes/no
11. Grafana remote access: SSH tunnel / Tailscale / skip
12. Cloudflare Tunnel for wallet: yes/no

After install, everything is configured and running. Config saved to `~/.canton/toolkit.conf`.

---

## Upgrade

### Manual (recommended)

```bash
~/canton-validator-toolkit/scripts/setup.sh
# → choose option 2: Update
```

The script detects your running version and the current network version, shows the diff, optionally runs a backup, then upgrades with minimum downtime:

1. Downloads new bundle
2. Migrates `.env`, `nginx.conf`, `.htpasswd` from old version
3. **Pre-pulls Docker images while old node is still running**
4. Stops old → starts new
5. Waits up to 90s for healthy status
6. If unhealthy: automatic rollback + Telegram alert

### Auto-upgrade (optional)

Disabled by default. To enable:

```bash
# During setup: answer "y" to auto-upgrade question
# Or edit config manually:
sed -i 's/AUTO_UPGRADE=false/AUTO_UPGRADE=true/' ~/.canton/toolkit.conf
```

Runs daily at 22:00 via cron. Safety rules:
- Skips if already on latest
- Skips if our version ≥ network version (anti-downgrade)
- Waits 12h after release before upgrading
- Major version bump → Telegram alert, exit (manual required)
- Always backs up before upgrading
- Rolls back automatically if new version is unhealthy

---

## How versioning works

Canton bundles are installed to `~/.canton/<version>/` and never modified after install. On each upgrade, `.env`, `nginx.conf`, and `nginx/` (including `.htpasswd`) are copied to the new version directory.

```
~/.canton/
├── 0.5.9/    ← old, kept for rollback
├── 0.5.10/   ← current
│   └── splice-node/docker-compose/validator/
│       ├── .env
│       ├── nginx.conf
│       ├── nginx/.htpasswd
│       └── compose.yaml   ← patched: port 8888, localhost-only
├── current -> 0.5.10/     ← symlink, updated on each successful upgrade
└── toolkit.conf           ← single config, survives all upgrades
```

Rolling back is as simple as starting the old version directory.

---

## Wallet access

Port 8888 is bound to `localhost` only — never exposed publicly.

**Via SSH tunnel (default):**

```bash
ssh -L 8888:localhost:8888 user@your-server -N
# Then open: http://wallet.localhost:8888
# Login: validator / <your password>
```

**Via Cloudflare Tunnel (optional):**
Set up during install. Access from anywhere at `https://wallet.yourdomain.com` with no open ports. See [docs/wallet-access.md](docs/wallet-access.md).

---

## CLI Wallet

```bash
TOOLKIT=~/canton-validator-toolkit

# Check balance
$TOOLKIT/scripts/transfer.sh balance

# Send CC
$TOOLKIT/scripts/transfer.sh send \
  --to "PARTY::1220..." \
  --amount 10.0 \
  --description "payment"

# Transaction history
$TOOLKIT/scripts/transfer.sh history --limit 20

# Pending outgoing offers
$TOOLKIT/scripts/transfer.sh offers
```

---

## Monitoring

Prometheus + Grafana + node-exporter. Enable during setup or start manually:

```bash
cd ~/canton-validator-toolkit/monitoring
CANTON_NETWORK_NAME=splice-validator docker compose up -d
```

`CANTON_NETWORK_NAME` must match your validator's Docker Compose project name. Default is `splice-validator`. If your containers are named `splice-devnet-*`, use `splice-devnet`. `setup.sh` detects this automatically.

**Access options:**
- SSH tunnel: `ssh -L 3001:localhost:3001 user@server -N` → `http://localhost:3001`
- Tailscale: enable during setup → Grafana available at `http://<tailscale-ip>:3001` from any device on your Tailscale network, no tunnel needed

- Prometheus: `http://localhost:9091`

![Canton Validator Dashboard](docs/img/dashboard-overview.png)

Dashboard includes 28 panels across 7 sections: Overview, Rewards & Economics, Network Health, Triggers, JVM, Database, System.

Prometheus scrapes `validator:10013` and `participant:10013` directly — not via nginx (standard Prometheus can't set custom `Host` headers).

Grafana alerts → Telegram. See [docs/monitoring.md](docs/monitoring.md).

---

## Backup

Configured during setup. Runs every 4h via cron.

```bash
# Manual backup
~/canton-validator-toolkit/scripts/backup.sh
```

Backs up both `validator` and `participant` PostgreSQL databases. Supports rsync (SSH) and Cloudflare R2. See [docs/backup.md](docs/backup.md).

---

## Health check

Runs every 15 minutes via cron. Checks:
- Container running + healthy status
- Sync lag (warn >60s, critical >120s)
- Retry failures
- Disk space (<20GB free)

One Telegram alert on failure, one on recovery — no spam.

```bash
# Manual run
~/canton-validator-toolkit/scripts/check_health.sh
```

---

## Logs

```
~/.canton/logs/
├── health.log    # check_health.sh output
├── backup.log    # backup.sh output
└── upgrade.log   # auto_upgrade.sh output
```

---

## Networks

| Network | SV | Scan | Version API |
|---------|----|------|-------------|
| MainNet | `sv.sv-2.global.canton.network.digitalasset.com` | `scan.sv-2.global...` | `/api/scan/version` |
| TestNet | `sv.sv-2.test.global.canton.network.digitalasset.com` | `scan.sv-2.test...` | `lighthouse.testnet.cantonloop.com/api/stats` |
| DevNet  | `sv.sv-2.dev.global.canton.network.digitalasset.com` | `scan.sv-2.dev...` | `lighthouse.devnet.cantonloop.com/api/stats` |

---

## Known issues

**ZodError on Wallet UI** — missing `SPLICE_APP_UI_*` env vars. Fixed automatically by setup and auto_upgrade scripts.

**wallet.localhost in Chrome** — use full `http://wallet.localhost:8888` with `http://` prefix. If Chrome redirects to HTTPS, use Firefox.

**docker-proxy `-use-listen-fd`** — on some Ubuntu versions port listens but doesn't accept connections after restart. Fix: `docker compose down && docker compose up -d` (not `docker restart`).

**Official Grafana dashboards** from the Canton bundle use `namespace` label (Kubernetes only). This toolkit's dashboard uses `job` and `node_name` labels which work in docker-compose.
