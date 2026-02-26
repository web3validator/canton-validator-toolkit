# Backup

The toolkit backs up both PostgreSQL databases — `validator` and `participant` — that Canton uses to store all on-chain state locally.

---

## How it works

1. `pg_dump` runs inside the postgres container — no need to expose any ports
2. Dumps are gzip-compressed locally
3. Uploaded to remote destination (rsync or R2)
4. Local dumps older than `RETENTION_DAYS` are deleted
5. Remote dumps older than `RETENTION_DAYS` are deleted
6. Telegram alert on failure only (no noise on success)

Runs every 4h via cron. Validator DB is dumped first — it must be consistent with participant.

---

## Configuration

All settings live in `~/.canton/toolkit.conf`. Set during install, edit anytime:

```
BACKUP_TYPE=rsync          # rsync | r2 | skip
REMOTE_HOST=ubuntu@142.132.158.158
REMOTE_PATH=~/canton-backups/mainnet
R2_BUCKET=
R2_ACCOUNT_ID=
R2_ACCESS_KEY=
R2_SECRET_KEY=
RETENTION_DAYS=1
```

After editing, the next cron run will use the new config.

---

## rsync (SSH)

Requirements:
- SSH key-based auth from validator server to backup server (no password prompts)
- `rsync` installed on both machines

Setup SSH key if not done:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_backup -N ""
ssh-copy-id -i ~/.ssh/id_backup.pub ubuntu@your-backup-server
```

Test connectivity:

```bash
ssh -o BatchMode=yes ubuntu@your-backup-server echo OK
```

In `toolkit.conf`:

```
BACKUP_TYPE=rsync
REMOTE_HOST=ubuntu@your-backup-server
REMOTE_PATH=~/canton-backups/mainnet
RETENTION_DAYS=1
```

---

## Cloudflare R2

Requirements:
- Cloudflare account with R2 enabled
- Bucket created (e.g. `canton-backups`)
- R2 API token with Object Read & Write permissions

Get credentials from Cloudflare dashboard → R2 → Manage R2 API tokens.

In `toolkit.conf`:

```
BACKUP_TYPE=r2
R2_BUCKET=canton-backups
R2_ACCOUNT_ID=abc123...
R2_ACCESS_KEY=your-access-key
R2_SECRET_KEY=your-secret-key
RETENTION_DAYS=7
```

`rclone` is installed automatically on first run if not present.

---

## Manual backup

```bash
~/canton-validator-toolkit/scripts/backup.sh
```

Output example:

```
[2024-01-15 14:00:01] Starting backup — network: mainnet, type: rsync
[2024-01-15 14:00:01] PostgreSQL container: splice-validator-postgres-splice-1
[2024-01-15 14:00:02] Dumping validator DB...
[2024-01-15 14:00:04] ✓ validator_20240115_140002.sql.gz — 45M
[2024-01-15 14:00:04] Dumping participant DB (participant_0)...
[2024-01-15 14:00:07] ✓ participant_0_20240115_140002.sql.gz — 120M
[2024-01-15 14:00:07] Syncing to ubuntu@142.132.158.158:~/canton-backups/mainnet ...
[2024-01-15 14:00:09] ✓ rsync upload complete
[2024-01-15 14:00:09] ✓ Backup completed successfully
```

---

## Restore

**Step 1 — Stop the validator:**

```bash
cd ~/.canton/current/splice-node/docker-compose/validator
./stop.sh
```

**Step 2 — Start only postgres:**

```bash
export IMAGE_TAG=$(cat ~/.canton/toolkit.conf | grep ^VERSION | cut -d= -f2)
docker compose up -d postgres-splice
sleep 10
```

**Step 3 — Restore validator DB:**

```bash
PG_CONTAINER=$(docker ps --format '{{.Names}}' | grep postgres-splice | head -1)

gunzip -c ~/path/to/validator_YYYYMMDD_HHMMSS.sql.gz \
  | docker exec -i $PG_CONTAINER psql -U cnadmin -d validator
```

**Step 4 — Restore participant DB:**

```bash
# Detect participant DB name (usually participant_0 or participant_1)
PARTICIPANT_DB=$(docker exec splice-validator-participant-1 \
  bash -c 'echo $CANTON_PARTICIPANT_POSTGRES_DB' 2>/dev/null || echo "participant_0")

gunzip -c ~/path/to/${PARTICIPANT_DB}_YYYYMMDD_HHMMSS.sql.gz \
  | docker exec -i $PG_CONTAINER psql -U cnadmin -d $PARTICIPANT_DB
```

**Step 5 — Start the validator:**

```bash
cd ~/.canton/current/splice-node/docker-compose/validator
source ~/.canton/toolkit.conf
./start.sh -s $SV_URL -c $SCAN_URL -p $PARTY_HINT -m $MIGRATION_ID -w
```

---

## Backup log

```bash
tail -f ~/.canton/logs/backup.log
```

---

## Planned extensions

**Encrypted backups** — GPG-encrypt dumps before upload. Needed if backup destination is shared or untrusted.

**S3-compatible targets** — rclone supports AWS S3, Backblaze B2, Storj, and others. Any rclone remote works once the config is in place.

**Point-in-time recovery** — WAL archiving for PostgreSQL, restore to any point in time between backup snapshots.

**Backup health panel** — Grafana panel showing last successful backup timestamp, alert if no backup in >6h.
