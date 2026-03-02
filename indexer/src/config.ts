import { readFileSync } from 'fs';
import { join } from 'path';

function loadEnv(): void {
  try {
    const envPath = join(process.cwd(), '.env');
    const content = readFileSync(envPath, 'utf8');
    for (const line of content.split('\n')) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith('#')) continue;
      const eq = trimmed.indexOf('=');
      if (eq === -1) continue;
      const key = trimmed.slice(0, eq).trim();
      const value = trimmed.slice(eq + 1).trim().replace(/^["']|["']$/g, '');
      if (!(key in process.env)) {
        process.env[key] = value;
      }
    }
  } catch {
    // no .env file — rely on real env vars
  }
}

loadEnv();

function required(key: string): string {
  const val = process.env[key];
  if (!val) throw new Error(`Missing required env var: ${key}`);
  return val;
}

function optional(key: string, fallback: string): string {
  return process.env[key] ?? fallback;
}

function optionalInt(key: string, fallback: number): number {
  const val = process.env[key];
  if (!val) return fallback;
  const n = parseInt(val, 10);
  return isNaN(n) ? fallback : n;
}

export type Network = 'mainnet' | 'testnet' | 'devnet';

const LIGHTHOUSE_BASE: Record<Network, string> = {
  mainnet: 'https://lighthouse.cantonloop.com',
  testnet: 'https://lighthouse.testnet.cantonloop.com',
  devnet: 'https://lighthouse.devnet.cantonloop.com',
};

const network = optional('CANTON_NETWORK', 'mainnet') as Network;
if (!['mainnet', 'testnet', 'devnet'].includes(network)) {
  throw new Error(`Invalid CANTON_NETWORK: ${network}. Must be mainnet | testnet | devnet`);
}

export const config = {
  server: {
    host: optional('HOST', '0.0.0.0'),
    port: optionalInt('PORT', 3000),
    logLevel: optional('LOG_LEVEL', 'info'),
  },

  network,

  lighthouse: {
    baseUrl: optional('LIGHTHOUSE_URL', LIGHTHOUSE_BASE[network]),
    timeoutMs: optionalInt('LIGHTHOUSE_TIMEOUT_MS', 10_000),
  },

  // Optional: local Validator API (JWT-authenticated)
  validatorApi: {
    enabled: optional('VALIDATOR_API_ENABLED', 'false') === 'true',
    baseUrl: optional('VALIDATOR_API_URL', 'http://localhost:10013'),
    jwtToken: optional('VALIDATOR_JWT_TOKEN', ''),
  },

  // Optional: SV Scan API (IP-whitelisted)
  scanApi: {
    enabled: optional('SCAN_API_ENABLED', 'false') === 'true',
    baseUrl: optional('SCAN_API_URL', ''),
  },

  db: {
    host: optional('DB_HOST', 'localhost'),
    port: optionalInt('DB_PORT', 5432),
    name: optional('DB_NAME', 'canton_indexer'),
    user: optional('DB_USER', 'canton'),
    password: optional('DB_PASSWORD', 'canton'),
    poolMax: optionalInt('DB_POOL_MAX', 10),
    // Full connection string takes priority if provided
    connectionString: optional('DATABASE_URL', ''),
  },

  polling: {
    // seconds
    statsAndPrices: optionalInt('POLL_STATS_SEC', 60),
    validatorsAndRounds: optionalInt('POLL_VALIDATORS_SEC', 300),
    rewardsAndTransactions: optionalInt('POLL_REWARDS_SEC', 900),
    governance: optionalInt('POLL_GOVERNANCE_SEC', 1800),
    fullSnapshot: optionalInt('POLL_SNAPSHOT_SEC', 3600),
  },

  cache: {
    // How long to serve stale data (ms) if upstream is down
    staleTtlMs: optionalInt('CACHE_STALE_TTL_MS', 300_000),
  },
} as const;

export type Config = typeof config;
