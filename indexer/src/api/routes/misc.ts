import { FastifyInstance } from "fastify";
import { queryRows, queryOne } from "../../storage/db.js";
import { lighthouse } from "../../collectors/lighthouse.js";
import { config } from "../../config.js";

export async function registerMiscRoutes(server: FastifyInstance): Promise<void> {
  // GET /api/cns
  server.get(
    "/cns",
    {
      schema: {
        tags: ["misc"],
        summary: "List Canton Name Service records",
        description:
          "Note: no CNS records currently exist on the network, but the endpoint is ready.",
        querystring: {
          type: "object",
          properties: {
            limit: { type: "integer", default: 50, maximum: 500 },
            live: { type: "boolean", description: "Force live fetch from Lighthouse" },
          },
        },
      },
    },
    async (req, reply) => {
      const q = req.query as Record<string, unknown>;
      const live = q["live"] === true || q["live"] === "true";
      const limit = Math.min(Number(q["limit"] ?? 50), 500);

      if (!live) {
        const rows = await queryRows<Record<string, unknown>>(
          `SELECT domain, party_id, captured_at, raw
         FROM cns_records
         WHERE network = $1
         ORDER BY captured_at DESC
         LIMIT $2`,
          [config.network, limit],
        );
        if (rows.length > 0) {
          return reply.send({
            network: config.network,
            count: rows.length,
            source: "indexed",
            data: rows,
          });
        }
      }

      const res = await lighthouse.getCnsRecords({ page_size: String(limit) } as never);
      if (!res.ok) {
        return reply.status(502).send({ error: "Upstream unavailable", detail: res.error });
      }
      const data = Array.isArray(res.data) ? res.data : [];
      return reply.send({
        network: config.network,
        count: data.length,
        source: "lighthouse",
        data,
      });
    },
  );

  // GET /api/cns/:domain
  server.get<{ Params: { domain: string } }>(
    "/cns/:domain",
    {
      schema: {
        tags: ["misc"],
        summary: "Get CNS record by domain name",
        params: {
          type: "object",
          properties: { domain: { type: "string" } },
          required: ["domain"],
        },
      },
    },
    async (req, reply) => {
      const { domain } = req.params;

      const row = await queryOne<Record<string, unknown>>(
        `SELECT domain, party_id, captured_at, raw
       FROM cns_records WHERE domain = $1 AND network = $2`,
        [domain, config.network],
      );
      if (row) return reply.send(row);

      const res = await lighthouse.getCnsRecord(domain);
      if (!res.ok) {
        const status = res.status === 404 ? 404 : 502;
        return reply.status(status).send({
          error: res.status === 404 ? "Not found" : "Upstream unavailable",
          detail: res.error,
        });
      }
      return reply.send(res.data);
    },
  );

  // GET /api/featured-apps
  server.get(
    "/featured-apps",
    {
      schema: {
        tags: ["misc"],
        summary: "List featured applications on Canton Network",
        querystring: {
          type: "object",
          properties: {
            live: { type: "boolean", description: "Force live fetch from Lighthouse" },
          },
        },
      },
    },
    async (req, reply) => {
      const q = req.query as Record<string, unknown>;
      const live = q["live"] === true || q["live"] === "true";

      if (!live) {
        const rows = await queryRows<Record<string, unknown>>(
          `SELECT name, party_id, captured_at, raw
         FROM featured_apps
         WHERE network = $1
         ORDER BY captured_at DESC`,
          [config.network],
        );
        if (rows.length > 0) {
          return reply.send({
            network: config.network,
            count: rows.length,
            source: "indexed",
            data: rows,
          });
        }
      }

      const res = await lighthouse.getFeaturedApps();
      if (!res.ok) {
        return reply.status(502).send({ error: "Upstream unavailable", detail: res.error });
      }
      const data = Array.isArray(res.data) ? res.data : [];
      return reply.send({
        network: config.network,
        count: data.length,
        source: "lighthouse",
        data,
      });
    },
  );

  // GET /api/preapprovals
  server.get(
    "/preapprovals",
    {
      schema: {
        tags: ["misc"],
        summary: "List preapproval records",
        querystring: {
          type: "object",
          properties: {
            limit: { type: "integer", default: 50, maximum: 500 },
            live: { type: "boolean", description: "Force live fetch from Lighthouse" },
          },
        },
      },
    },
    async (req, reply) => {
      const q = req.query as Record<string, unknown>;
      const live = q["live"] === true || q["live"] === "true";
      const limit = Math.min(Number(q["limit"] ?? 50), 500);

      if (!live) {
        const rows = await queryRows<Record<string, unknown>>(
          `SELECT id, captured_at, raw
         FROM preapprovals
         WHERE network = $1
         ORDER BY captured_at DESC
         LIMIT $2`,
          [config.network, limit],
        );
        if (rows.length > 0) {
          return reply.send({
            network: config.network,
            count: rows.length,
            source: "indexed",
            data: rows,
          });
        }
      }

      const res = await lighthouse.getPreapprovals({ page_size: String(limit) } as never);
      if (!res.ok) {
        return reply.status(502).send({ error: "Upstream unavailable", detail: res.error });
      }
      const data = Array.isArray(res.data) ? res.data : [];
      return reply.send({
        network: config.network,
        count: data.length,
        source: "lighthouse",
        data,
      });
    },
  );

  // GET /api/search
  server.get(
    "/search",
    {
      schema: {
        tags: ["misc"],
        summary: "Universal search across all Canton Network entities",
        querystring: {
          type: "object",
          required: ["q"],
          properties: {
            q: { type: "string", minLength: 2, description: "Search query" },
          },
        },
      },
    },
    async (req, reply) => {
      const q = (req.query as Record<string, unknown>)["q"] as string;
      if (!q || q.length < 2) {
        return reply.status(400).send({ error: "Query must be at least 2 characters" });
      }

      // Run local DB search and Lighthouse search in parallel
      const [localResults, lighthouseRes] = await Promise.allSettled([
        searchLocal(q),
        lighthouse.search(q),
      ]);

      const local = localResults.status === "fulfilled" ? localResults.value : [];
      const remote =
        lighthouseRes.status === "fulfilled" && lighthouseRes.value.ok
          ? lighthouseRes.value.data
          : null;

      return reply.send({
        network: config.network,
        query: q,
        indexed: { count: local.length, data: local },
        lighthouse: remote,
      });
    },
  );

  // GET /api/network/health — custom aggregated health score
  server.get(
    "/network/health",
    {
      schema: {
        tags: ["misc"],
        summary: "Aggregated network health from all sources",
        description:
          "Combines Lighthouse stats, validator count, latest round, and price data into a single health snapshot.",
      },
    },
    async (_req, reply) => {
      const [statsRes, validatorsRes] = await Promise.allSettled([
        lighthouse.getStats(),
        lighthouse.getValidators({ page_size: "200" }),
      ]);

      const stats =
        statsRes.status === "fulfilled" && statsRes.value.ok ? statsRes.value.data : null;
      const validatorsData =
        validatorsRes.status === "fulfilled" && validatorsRes.value.ok
          ? validatorsRes.value.data
          : null;

      const validatorList = validatorsData?.validators ?? [];
      const activeValidators = validatorList.filter((v) => v.last_active_at).length;

      return reply.send({
        network: config.network,
        status: stats !== null ? "ok" : "down",
        checked_at: new Date().toISOString(),
        stats: stats
          ? {
              cc_price: stats.cc_price ?? null,
              total_validators: stats.total_validator ?? null,
              total_sv: stats.total_sv ?? null,
              total_parties: stats.total_parties ?? null,
              total_transaction: stats.total_transaction ?? null,
              active_validators: activeValidators || null,
            }
          : null,
        price_usd: stats?.cc_price ?? null,
      });
    },
  );
}

// ── Local full-text search across indexed tables ──────────────────────────────

interface SearchHit {
  type: string;
  id: string;
  snippet: Record<string, unknown>;
}

async function searchLocal(q: string): Promise<SearchHit[]> {
  const results: SearchHit[] = [];
  const like = `%${q}%`;

  const [validators, transactions, transfers, contracts, cns] = await Promise.allSettled([
    queryRows<{ id: string; name: string | null; party_id: string | null }>(
      `SELECT id, name, party_id FROM validators
       WHERE (name ILIKE $1 OR party_id ILIKE $1 OR id ILIKE $1)
       LIMIT 10`,
      [like],
    ),
    queryRows<{ update_id: string; created_at: string | null }>(
      `SELECT update_id, created_at FROM transactions
       WHERE update_id ILIKE $1
       LIMIT 10`,
      [like],
    ),
    queryRows<{
      id: string;
      sender: string | null;
      receiver: string | null;
      amount: string | null;
    }>(
      `SELECT id, sender, receiver, amount FROM transfers
       WHERE (sender ILIKE $1 OR receiver ILIKE $1 OR id ILIKE $1)
       LIMIT 10`,
      [like],
    ),
    queryRows<{ contract_id: string; template_id: string | null }>(
      `SELECT contract_id, template_id FROM contracts
       WHERE (contract_id ILIKE $1 OR template_id ILIKE $1)
       LIMIT 10`,
      [like],
    ),
    queryRows<{ domain: string; party_id: string | null }>(
      `SELECT domain, party_id FROM cns_records
       WHERE (domain ILIKE $1 OR party_id ILIKE $1)
       LIMIT 10`,
      [like],
    ),
  ]);

  if (validators.status === "fulfilled") {
    for (const v of validators.value) {
      results.push({ type: "validator", id: v.id, snippet: v as Record<string, unknown> });
    }
  }
  if (transactions.status === "fulfilled") {
    for (const t of transactions.value) {
      results.push({ type: "transaction", id: t.update_id, snippet: t as Record<string, unknown> });
    }
  }
  if (transfers.status === "fulfilled") {
    for (const t of transfers.value) {
      results.push({ type: "transfer", id: t.id, snippet: t as Record<string, unknown> });
    }
  }
  if (contracts.status === "fulfilled") {
    for (const c of contracts.value) {
      results.push({ type: "contract", id: c.contract_id, snippet: c as Record<string, unknown> });
    }
  }
  if (cns.status === "fulfilled") {
    for (const r of cns.value) {
      results.push({ type: "cns", id: r.domain, snippet: r as Record<string, unknown> });
    }
  }

  return results;
}
