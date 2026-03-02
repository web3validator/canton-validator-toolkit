import cron from "node-cron";
import { config } from "./config.js";
import { lighthouse } from "./collectors/lighthouse.js";
import { query } from "./storage/db.js";

function secToCron(seconds: number): string {
  if (seconds < 60) return `*/${seconds} * * * * *`;
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return `*/${minutes} * * * *`;
  const hours = Math.round(minutes / 60);
  return `0 */${hours} * * *`;
}

const network = config.network;

// ── Pollers ───────────────────────────────────────────────────────────────────

async function pollStats(): Promise<void> {
  const res = await lighthouse.getStats();
  if (!res.ok) {
    console.warn(`[scheduler] stats failed: ${res.error}`);
    return;
  }
  const d = res.data;
  const ccPrice = d.cc_price ? parseFloat(d.cc_price) : null;

  await query(
    `INSERT INTO stats_snapshots (network, version, total_validators, total_rounds, cc_price, raw)
     VALUES ($1, $2, $3, $4, $5, $6)`,
    [
      network,
      null, // stats response has no version field — version comes from validator.version
      d.total_validator ?? null,
      null, // no total_rounds in stats — rounds are tracked separately
      ccPrice,
      JSON.stringify(d),
    ],
  );

  // Persist price to prices table for history tracking
  if (ccPrice !== null && !isNaN(ccPrice)) {
    await query(`INSERT INTO prices (network, price_usd, raw) VALUES ($1, $2, $3)`, [
      network,
      ccPrice,
      JSON.stringify({ cc_price: d.cc_price, captured_from: "stats" }),
    ]);
  }

  console.log(
    `[scheduler] stats snapshot saved (cc_price=${d.cc_price}, validators=${d.total_validator})`,
  );
}

async function pollValidators(): Promise<void> {
  const res = await lighthouse.getValidators({ page_size: "200" });
  if (!res.ok) {
    console.warn(`[scheduler] validators failed: ${res.error}`);
    return;
  }

  const validators = res.data.validators ?? [];
  for (const v of validators) {
    if (!v.id) continue;
    await query(
      `INSERT INTO validators (id, network, name, party_id, is_active, version, last_seen_at, raw)
       VALUES ($1, $2, $3, $4, $5, $6, NOW(), $7)
       ON CONFLICT (id) DO UPDATE SET
         is_active    = EXCLUDED.is_active,
         version      = EXCLUDED.version,
         last_seen_at = NOW(),
         raw          = EXCLUDED.raw`,
      [
        v.id,
        network,
        null,
        null,
        v.last_active_at ? true : false,
        v.version ?? null,
        JSON.stringify(v),
      ],
    );
    await query(
      `INSERT INTO validator_snapshots (validator_id, network, is_active, raw)
       VALUES ($1, $2, $3, $4)`,
      [v.id, network, v.last_active_at ? true : false, JSON.stringify(v)],
    );
  }
  console.log(`[scheduler] validators upserted: ${validators.length}`);
}

async function pollRounds(): Promise<void> {
  const res = await lighthouse.getRounds({ page_size: "50" });
  if (!res.ok) {
    console.warn(`[scheduler] rounds failed: ${res.error}`);
    return;
  }
  const rounds = res.data.rounds ?? [];
  let inserted = 0;
  for (const r of rounds) {
    if (!r.round) continue;
    const result = await query(
      `INSERT INTO rounds (round, network, created_at, raw)
       VALUES ($1, $2, $3, $4)
       ON CONFLICT (round, network) DO NOTHING`,
      [r.round, network, r.open_at ?? null, JSON.stringify(r)],
    );
    inserted += result.rowCount ?? 0;
  }
  console.log(`[scheduler] rounds: ${rounds.length} fetched, ${inserted} new`);
}

async function pollTransactions(): Promise<void> {
  const res = await lighthouse.getTransactions({ page_size: "100" });
  if (!res.ok) {
    console.warn(`[scheduler] transactions failed: ${res.error}`);
    return;
  }
  const txs = res.data.transactions ?? [];
  let inserted = 0;
  for (const tx of txs) {
    if (!tx.update_id) continue;
    const result = await query(
      `INSERT INTO transactions (update_id, network, created_at, raw)
       VALUES ($1, $2, $3, $4)
       ON CONFLICT (update_id, network) DO NOTHING`,
      [tx.update_id, network, tx.record_time ?? null, JSON.stringify(tx)],
    );
    inserted += result.rowCount ?? 0;
  }
  console.log(`[scheduler] transactions: ${txs.length} fetched, ${inserted} new`);
}

async function pollTransfers(): Promise<void> {
  const res = await lighthouse.getTransfers({ page_size: "100" });
  if (!res.ok) {
    console.warn(`[scheduler] transfers failed: ${res.error}`);
    return;
  }
  const transfers = res.data.transfers ?? [];
  let inserted = 0;
  for (const t of transfers) {
    const id = String(t.id);
    if (!id) continue;
    const result = await query(
      `INSERT INTO transfers (id, network, created_at, sender, receiver, amount, raw)
       VALUES ($1, $2, $3, $4, $5, $6, $7)
       ON CONFLICT (id, network) DO NOTHING`,
      [
        id,
        network,
        t.created_at ?? null,
        t.sender_address ?? null,
        t.receiver_address ?? null,
        t.amount ?? null,
        JSON.stringify(t),
      ],
    );
    inserted += result.rowCount ?? 0;
  }
  console.log(`[scheduler] transfers: ${transfers.length} fetched, ${inserted} new`);
}

async function pollGovernance(): Promise<void> {
  const [votesRes, statsRes] = await Promise.all([
    lighthouse.getGovernanceVotes({ page_size: "100" }),
    lighthouse.getGovernanceStats(),
  ]);

  if (votesRes.ok) {
    const votes = votesRes.data.vote_requests ?? [];
    for (const v of votes) {
      if (!v.id) continue;
      await query(
        `INSERT INTO governance_votes (id, network, raw)
         VALUES ($1, $2, $3)
         ON CONFLICT (id, network) DO UPDATE SET raw = EXCLUDED.raw`,
        [v.id, network, JSON.stringify(v)],
      );
    }
    console.log(`[scheduler] governance votes upserted: ${votes.length}`);
  } else {
    console.warn(`[scheduler] governance votes failed: ${votesRes.error}`);
  }

  if (statsRes.ok) {
    await query(`INSERT INTO governance_stats_snapshots (network, raw) VALUES ($1, $2)`, [
      network,
      JSON.stringify(statsRes.data),
    ]);
  }
}

async function pollCns(): Promise<void> {
  const res = await lighthouse.getCnsRecords({ page_size: "100" });
  if (!res.ok) {
    console.warn(`[scheduler] cns failed: ${res.error}`);
    return;
  }
  const records = res.data.cns ?? [];
  let upserted = 0;
  for (const r of records) {
    if (!r.domain_name) continue;
    await query(
      `INSERT INTO cns_records (domain, network, party_id, raw)
       VALUES ($1, $2, $3, $4)
       ON CONFLICT (domain, network) DO UPDATE SET
         party_id = EXCLUDED.party_id,
         raw      = EXCLUDED.raw`,
      [r.domain_name, network, r.party_address ?? null, JSON.stringify(r)],
    );
    upserted++;
  }
  if (upserted > 0) console.log(`[scheduler] cns records upserted: ${upserted}`);
}

async function pollFeaturedApps(): Promise<void> {
  const res = await lighthouse.getFeaturedApps();
  if (!res.ok) {
    console.warn(`[scheduler] featured-apps failed: ${res.error}`);
    return;
  }
  const apps = res.data.apps ?? [];
  for (const app of apps) {
    const provider = app.payload?.["provider"] as string | undefined;
    if (!provider) continue;
    await query(
      `INSERT INTO featured_apps (name, network, party_id, raw)
       VALUES ($1, $2, $3, $4)
       ON CONFLICT (name, network) DO UPDATE SET
         party_id   = EXCLUDED.party_id,
         captured_at = NOW(),
         raw        = EXCLUDED.raw`,
      [provider, network, provider, JSON.stringify(app)],
    );
  }
  if (apps.length > 0) console.log(`[scheduler] featured apps upserted: ${apps.length}`);
}

async function pollPreapprovals(): Promise<void> {
  const res = await lighthouse.getPreapprovals({ page_size: "100" });
  if (!res.ok) {
    console.warn(`[scheduler] preapprovals failed: ${res.error}`);
    return;
  }
  const items = res.data.preapprovals ?? [];
  let upserted = 0;
  for (const p of items) {
    const id = String(p.id);
    if (!id) continue;
    await query(
      `INSERT INTO preapprovals (id, network, raw)
       VALUES ($1, $2, $3)
       ON CONFLICT (id, network) DO UPDATE SET raw = EXCLUDED.raw`,
      [id, network, JSON.stringify(p)],
    );
    upserted++;
  }
  if (upserted > 0) console.log(`[scheduler] preapprovals upserted: ${upserted}`);
}

async function pollFullSnapshot(): Promise<void> {
  console.log("[scheduler] full snapshot start");
  await Promise.allSettled([
    pollStats(),
    pollValidators(),
    pollRounds(),
    pollTransactions(),
    pollTransfers(),
    pollGovernance(),
    pollCns(),
    pollFeaturedApps(),
    pollPreapprovals(),
  ]);
  console.log("[scheduler] full snapshot done");
}

// ── Scheduler ────────────────────────────────────────────────────────────────

let started = false;

export function startScheduler(): void {
  if (started) return;
  started = true;

  const p = config.polling;

  // Run immediately on start
  void pollFullSnapshot();

  cron.schedule(secToCron(p.statsAndPrices), async () => {
    await pollStats();
  });

  cron.schedule(secToCron(p.validatorsAndRounds), async () => {
    await Promise.allSettled([pollValidators(), pollRounds()]);
  });

  cron.schedule(secToCron(p.rewardsAndTransactions), async () => {
    await Promise.allSettled([pollTransactions(), pollTransfers()]);
  });

  cron.schedule(secToCron(p.governance), async () => {
    await Promise.allSettled([pollGovernance(), pollCns(), pollFeaturedApps(), pollPreapprovals()]);
  });

  cron.schedule(secToCron(p.fullSnapshot), async () => {
    await pollFullSnapshot();
  });

  console.log("[scheduler] started", {
    network,
    statsAndPrices: `${p.statsAndPrices}s`,
    validatorsAndRounds: `${p.validatorsAndRounds}s`,
    rewardsAndTransactions: `${p.rewardsAndTransactions}s`,
    governance: `${p.governance}s`,
    fullSnapshot: `${p.fullSnapshot}s`,
  });
}

export function stopScheduler(): void {
  cron.getTasks().forEach((task) => task.stop());
  started = false;
  console.log("[scheduler] stopped");
}
