-- Canton Network Indexer — PostgreSQL Schema
-- Run: psql -U canton -d canton_indexer -f schema.sql

-- ── Extensions ───────────────────────────────────────────────────────────────

CREATE EXTENSION IF NOT EXISTS "pg_trgm"; -- full-text search

-- ── Network Stats Snapshots ───────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS stats_snapshots (
  id               BIGSERIAL PRIMARY KEY,
  network          TEXT        NOT NULL,
  captured_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  version          TEXT,
  total_validators INTEGER,
  total_rounds     BIGINT,
  cc_price         NUMERIC(20, 8),
  raw              JSONB       NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_stats_snapshots_network_captured
  ON stats_snapshots (network, captured_at DESC);

-- ── Validators ────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS validators (
  id            TEXT        PRIMARY KEY,
  network       TEXT        NOT NULL,
  name          TEXT,
  party_id      TEXT,
  is_active     BOOLEAN,
  version       TEXT,
  first_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_seen_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  raw           JSONB       NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_validators_network ON validators (network);
CREATE INDEX IF NOT EXISTS idx_validators_party_id ON validators (party_id);

-- ── Validator Uptime Snapshots ────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS validator_snapshots (
  id            BIGSERIAL   PRIMARY KEY,
  validator_id  TEXT        NOT NULL REFERENCES validators(id) ON DELETE CASCADE,
  network       TEXT        NOT NULL,
  captured_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  is_active     BOOLEAN,
  raw           JSONB       NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_validator_snapshots_validator_captured
  ON validator_snapshots (validator_id, captured_at DESC);

-- ── Rounds ────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS rounds (
  round         BIGINT      NOT NULL,
  network       TEXT        NOT NULL,
  captured_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at    TIMESTAMPTZ,
  raw           JSONB       NOT NULL,
  PRIMARY KEY (round, network)
);

CREATE INDEX IF NOT EXISTS idx_rounds_network_round ON rounds (network, round DESC);

-- ── Transactions ──────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS transactions (
  update_id     TEXT        NOT NULL,
  network       TEXT        NOT NULL,
  captured_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at    TIMESTAMPTZ,   -- maps to record_time from Lighthouse API
  round         BIGINT,
  raw           JSONB       NOT NULL,
  PRIMARY KEY (update_id, network)
);

CREATE INDEX IF NOT EXISTS idx_transactions_network_created
  ON transactions (network, created_at DESC NULLS LAST);
CREATE INDEX IF NOT EXISTS idx_transactions_round
  ON transactions (network, round DESC NULLS LAST);
CREATE INDEX IF NOT EXISTS idx_transactions_raw_gin
  ON transactions USING gin (raw);

-- ── Transfers ─────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS transfers (
  id            TEXT        NOT NULL,  -- numeric id from Lighthouse, stored as TEXT
  network       TEXT        NOT NULL,
  captured_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at    TIMESTAMPTZ,
  sender        TEXT,                  -- sender_address from Lighthouse
  receiver      TEXT,                  -- receiver_address from Lighthouse
  amount        NUMERIC(30, 10),
  round         BIGINT,
  raw           JSONB       NOT NULL,
  PRIMARY KEY (id, network)
);

CREATE INDEX IF NOT EXISTS idx_transfers_network_created
  ON transfers (network, created_at DESC NULLS LAST);
CREATE INDEX IF NOT EXISTS idx_transfers_sender   ON transfers (sender);
CREATE INDEX IF NOT EXISTS idx_transfers_receiver ON transfers (receiver);

-- ── Rewards ───────────────────────────────────────────────────────────────────

-- Rewards have three components: app_reward, validator_reward, sv_reward
CREATE TABLE IF NOT EXISTS rewards (
  id                BIGINT      NOT NULL,  -- numeric id from Lighthouse
  network           TEXT        NOT NULL,
  party_id          TEXT        NOT NULL,
  round             BIGINT,
  app_reward        NUMERIC(30, 10),
  validator_reward  NUMERIC(30, 10),
  sv_reward         NUMERIC(30, 10),
  captured_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at        TIMESTAMPTZ,
  raw               JSONB       NOT NULL,
  PRIMARY KEY (id, network, party_id)
);

CREATE INDEX IF NOT EXISTS idx_rewards_party_network
  ON rewards (party_id, network, created_at DESC NULLS LAST);
CREATE INDEX IF NOT EXISTS idx_rewards_network_round
  ON rewards (network, round DESC NULLS LAST);

-- ── Prices ────────────────────────────────────────────────────────────────────

-- Prices are extracted from /api/stats cc_price field (no separate prices endpoint)
CREATE TABLE IF NOT EXISTS prices (
  id            BIGSERIAL   PRIMARY KEY,
  network       TEXT        NOT NULL,
  price_usd     NUMERIC(20, 8) NOT NULL,
  captured_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  raw           JSONB       NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_prices_network_captured
  ON prices (network, captured_at DESC);

-- ── Governance Votes ──────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS governance_votes (
  id            TEXT        NOT NULL,
  network       TEXT        NOT NULL,
  captured_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  raw           JSONB       NOT NULL,
  PRIMARY KEY (id, network)
);

CREATE INDEX IF NOT EXISTS idx_governance_votes_network ON governance_votes (network);

-- ── Governance Stats Snapshots ────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS governance_stats_snapshots (
  id            BIGSERIAL   PRIMARY KEY,
  network       TEXT        NOT NULL,
  captured_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  raw           JSONB       NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_governance_stats_network_captured
  ON governance_stats_snapshots (network, captured_at DESC);

-- ── Contracts ─────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS contracts (
  contract_id   TEXT        NOT NULL,
  network       TEXT        NOT NULL,
  template_id   TEXT,
  captured_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  raw           JSONB       NOT NULL,
  PRIMARY KEY (contract_id, network)
);

CREATE INDEX IF NOT EXISTS idx_contracts_network       ON contracts (network);
CREATE INDEX IF NOT EXISTS idx_contracts_template_id   ON contracts (template_id);
CREATE INDEX IF NOT EXISTS idx_contracts_raw_gin
  ON contracts USING gin (raw);

-- ── CNS Records ───────────────────────────────────────────────────────────────

-- CNS: domain_name field from Lighthouse (not "domain")
CREATE TABLE IF NOT EXISTS cns_records (
  domain        TEXT        NOT NULL,  -- stores domain_name from Lighthouse
  network       TEXT        NOT NULL,
  party_id      TEXT,                  -- stores party_address from Lighthouse
  captured_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  raw           JSONB       NOT NULL,
  PRIMARY KEY (domain, network)
);

CREATE INDEX IF NOT EXISTS idx_cns_records_party_id ON cns_records (party_id);

-- ── Featured Apps ─────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS featured_apps (
  name          TEXT        NOT NULL,
  network       TEXT        NOT NULL,
  party_id      TEXT,
  captured_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  raw           JSONB       NOT NULL,
  PRIMARY KEY (name, network)
);

-- ── Preapprovals ──────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS preapprovals (
  id            TEXT        NOT NULL,
  network       TEXT        NOT NULL,
  captured_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  raw           JSONB       NOT NULL,
  PRIMARY KEY (id, network)
);

-- ── Schema Version Tracking ───────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS schema_migrations (
  version       TEXT        PRIMARY KEY,
  applied_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO schema_migrations (version)
VALUES ('001_initial')
ON CONFLICT (version) DO NOTHING;

-- ── API Notes ─────────────────────────────────────────────────────────────────
-- Verified against live Lighthouse API (testnet/mainnet, 2026-03-02):
--   - /api/prices/latest → 404 (does not exist); price is in /api/stats as cc_price
--   - /api/validators   → {count, validators:[]} (not a flat array)
--   - /api/transactions → {pagination, transactions:[]}; timestamp field is record_time
--   - /api/transfers    → {pagination, transfers:[]}; id is numeric, sender_address/receiver_address
--   - /api/rounds       → {pagination, rounds:[]}; timestamp field is open_at
--   - /api/governance   → {count, total_sv, vote_requests:[]}
--   - /api/featured-apps → {apps:[{payload:{provider}, created_at, contract_id}]}
--   - /api/cns          → {cns:[{domain_name, url, party_address, expires_at}]}
--   - /api/preapprovals → {pagination, preapprovals:[{id(numeric), expired_at, provider, receiver}]}
--   - /api/rewards (party) → {pagination, rewards:[{id, round, app_reward, validator_reward, sv_reward}]}
