# Canton Network Indexer

Unified REST API for Canton Network — aggregates data from the Lighthouse Explorer, SV Scan API, Validator and Participant APIs into a single queryable layer with historical persistence.

## Why

Canton doesn't expose a single endpoint with full network state. Data is scattered across:
- **Lighthouse Explorer** (public, 27 endpoints)
- **SV Scan API** (per-SV, IP-whitelisted)
- **Local Validator/Participant API** (JWT-authenticated)

The Indexer normalizes and persists this data, adding historical tracking that the public APIs don't provide (e.g. price history beyond 24h, reward history per validator, uptime tracking).

## Quick Start

```bash
cp .env.example .env
# Edit .env — set CANTON_NETWORK (mainnet/testnet/devnet)

docker compose up -d
```

API available at `http://localhost:3000`  
Docs (Swagger UI) at `http://localhost:3000/docs`

## API Endpoints

| Endpoint | Description |
|----------|-------------|
| `GET /health` | Health check + DB status |
| `GET /api/stats` | Latest network stats |
| `GET /api/stats/history` | Historical stats snapshots |
| `GET /api/validators` | All validators |
| `GET /api/validators/:id` | Validator by ID |
| `GET /api/validators/:id/uptime` | Uptime history |
| `GET /api/validators/:id/rewards/history` | Historical rewards (persisted) |
| `GET /api/parties/:id/balance` | CC balance |
| `GET /api/parties/:id/rewards` | Rewards (+ daily/weekly aggregation) |
| `GET /api/parties/:id/reward-stats` | Aggregated reward stats |
| `GET /api/parties/:id/transfers` | Transfers (sent/received) |
| `GET /api/parties/:id/transactions` | Transactions |
| `GET /api/parties/:id/burns` | Burns |
| `GET /api/parties/:id/burn-stats` | Burn stats |
| `GET /api/parties/:id/pnl` | Profit/loss |
| `GET /api/rewards/leaderboard` | Top earners ranking |
| `GET /api/transactions` | Transactions (+ date range filter) |
| `GET /api/transactions/:updateId` | Transaction by update ID |
| `GET /api/transfers` | Transfers (+ sender/receiver filter) |
| `GET /api/rounds` | Consensus rounds |
| `GET /api/rounds/:number` | Round by number |
| `GET /api/governance` | Governance vote requests |
| `GET /api/governance/stats` | Governance stats |
| `GET /api/governance/:id` | Vote request by ID |
| `GET /api/prices/latest` | Latest CC price in USD |
| `GET /api/prices/history` | Extended price history (beyond Lighthouse 24h) |
| `GET /api/cns` | Canton Name Service records |
| `GET /api/cns/:domain` | CNS record by domain |
| `GET /api/featured-apps` | Featured applications |
| `GET /api/preapprovals` | Preapproval records |
| `GET /api/search?q=...` | Universal search across all entities |
| `GET /api/network/health` | Aggregated network health score |

All list endpoints support `?live=true` to force a fresh fetch from Lighthouse, bypassing the local cache.

## Added Value Over Lighthouse

| Feature | Lighthouse | Indexer |
|---------|-----------|---------|
| Price history | 24h only | Unlimited (persisted) |
| Reward history | Current only | Full history per party |
| Validator uptime | Not available | Snapshot-based tracking |
| Transfer filtering | None | By sender, receiver, date range |
| Search | Basic | DB + Lighthouse combined |
| Network health | Not available | Aggregated score |
| Rewards leaderboard | Not available | Top earners ranking |

## Configuration

See `.env.example` for all options. Key variables:

```
CANTON_NETWORK=mainnet        # mainnet | testnet | devnet
PORT=3000
DATABASE_URL=postgres://...   # or use DB_HOST/DB_PORT/DB_NAME/DB_USER/DB_PASSWORD
POLL_STATS_SEC=60             # polling intervals in seconds
```

## Development

```bash
npm install
npm run dev          # ts-node with hot reload
npm run typecheck    # type check without building
npm run build        # compile to dist/
npm start            # run compiled
```

## Known Lighthouse API Limitations

- `GET /api/transfers/:id` — HTTP 500 (server-side bug), not implemented
- `/sv` super validators endpoint — doesn't exist on public API
- `/me` participant info — not on public API
- CNS records — API ready but no records exist on the network yet
- Some party balance queries return 500 if no data for that party

## Networks

| Network | Lighthouse Base URL |
|---------|---------------------|
| MainNet | `https://lighthouse.cantonloop.com` |
| TestNet | `https://lighthouse.testnet.cantonloop.com` |
| DevNet  | `https://lighthouse.devnet.cantonloop.com` |

## License

MIT