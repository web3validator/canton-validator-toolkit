# Quick Start

Get a Canton validator up and running in one command.

---

## Prerequisites

- Ubuntu 20.04+ with root/sudo
- Docker + Docker Compose plugin v2
- Ports: nothing needs to be open publicly (wallet is localhost-only)

Install dependencies if missing:

```bash
sudo apt-get update && sudo apt-get install -y \
  docker.io docker-compose-plugin \
  curl jq python3 openssl rsync git
```

---

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/web3validator/canton-validator-toolkit/main/install.sh | bash
```

This will:
1. Check dependencies
2. Clone the toolkit to `~/canton-validator-toolkit`
3. Launch the interactive setup

---

## Setup walkthrough

```
What do you want to do?
  1) Install Canton validator (fresh setup)
  2) Update to latest version
  3) Show status
  4) Exit
```

Choose `1` for fresh install. You'll be asked:

| Prompt | Example | Notes |
|--------|---------|-------|
| Network | `mainnet` | mainnet / testnet / devnet |
| Party hint | `MyOrg-validator-1` | your validator identity |
| Migration ID | `4` | 4 for mainnet, 1 for testnet/devnet |
| SV URL | auto-filled | default provided per network |
| Scan URL | auto-filled | default provided per network |
| Onboarding secret | *(empty)* | leave empty if already onboarded |
| Wallet password | `yourpassword` | for nginx basic auth |
| Backup | `rsync` | rsync / r2 / skip |
| Telegram | optional | bot token + chat ID |
| Auto-upgrade | `n` | disabled by default |
| Monitoring | `y` | Prometheus + Grafana |
| Cloudflare Tunnel | `n` | optional remote wallet access |

---

## After install

**Check it's running:**

```bash
docker ps | grep splice-validator
```

You should see `validator`, `participant`, `postgres`, `nginx` containers — all healthy within ~3 minutes.

**Check status:**

```bash
~/canton-validator-toolkit/scripts/setup.sh
# → option 3: Show status
```

**Access wallet:**

```bash
# On your local machine:
ssh -L 8888:127.0.0.1:8888 user@your-server -N &
# Then open: http://wallet.localhost:8888
# Login: validator / <your password>
```

---

## Upgrade

When a new Canton version is released:

```bash
~/canton-validator-toolkit/scripts/setup.sh
# → option 2: Update
```

The script detects the new version, pre-pulls images while the old node runs, then switches with minimal downtime. Rolls back automatically if something goes wrong.

---

## File locations

| Path | Description |
|------|-------------|
| `~/.canton/toolkit.conf` | Main config — all settings |
| `~/.canton/current/` | Symlink to active Canton version |
| `~/.canton/<version>/` | Versioned bundle (never modified) |
| `~/.canton/logs/` | Health, backup, upgrade logs |
| `~/canton-validator-toolkit/` | Toolkit scripts |

---

## Cron jobs installed

```
*/15 * * * *   check_health.sh   # health check + Telegram alerts
0    */4 * * * backup.sh         # database backup (if configured)
0    22  * * * auto_upgrade.sh   # auto-upgrade (only if enabled)
```

---

## Next steps

- [Backup setup](backup.md)
- [Monitoring & Grafana](monitoring.md)
- [Wallet remote access](wallet-access.md)