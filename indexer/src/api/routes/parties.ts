import { FastifyInstance } from "fastify";
import { queryRows, queryOne } from "../../storage/db.js";
import { lighthouse } from "../../collectors/lighthouse.js";
import { config } from "../../config.js";

export async function registerPartyRoutes(server: FastifyInstance): Promise<void> {
  // GET /api/parties/:id/balance
  server.get<{ Params: { id: string } }>(
    "/parties/:id/balance",
    {
      schema: {
        tags: ["parties"],
        summary: "Get CC balance for a party",
        params: {
          type: "object",
          properties: { id: { type: "string" } },
          required: ["id"],
        },
        querystring: {
          type: "object",
          properties: {
            live: { type: "boolean", description: "Force live fetch from Lighthouse" },
          },
        },
      },
    },
    async (req, reply) => {
      const { id } = req.params;
      const q = req.query as Record<string, unknown>;
      const live = q["live"] === true || q["live"] === "true";

      if (!live) {
        // Check if we have a recent cached balance (within 2 minutes)
        const row = await queryOne<{ price_usd: string; captured_at: string }>(
          `SELECT raw, captured_at FROM stats_snapshots
         WHERE network = $1 AND captured_at > NOW() - INTERVAL '2 minutes'
         LIMIT 1`,
          [config.network],
        );
        // Balance isn't stored separately — always fetch live but with graceful error
        void row; // suppress unused warning
      }

      const res = await lighthouse.getPartyBalance(id);
      if (!res.ok) {
        const status = res.status === 404 ? 404 : res.status === 500 ? 404 : 502;
        return reply.status(status).send({
          error: res.status === 500 ? "No balance data for this party" : "Upstream unavailable",
          detail: res.error,
          party_id: id,
        });
      }
      return reply.send(Object.assign({}, res.data as object, { network: config.network }));
    },
  );

  // GET /api/parties/:id/rewards
  server.get<{ Params: { id: string } }>(
    "/parties/:id/rewards",
    {
      schema: {
        tags: ["parties"],
        summary: "List rewards earned by a party",
        params: {
          type: "object",
          properties: { id: { type: "string" } },
          required: ["id"],
        },
        querystring: {
          type: "object",
          properties: {
            limit: { type: "integer", default: 100, maximum: 500 },
            from: { type: "string", description: "ISO8601 start date" },
            to: { type: "string", description: "ISO8601 end date" },
            aggregate: {
              type: "string",
              enum: ["day", "week", "month"],
              description: "Aggregate rewards by period",
            },
            live: { type: "boolean", description: "Force live fetch from Lighthouse" },
          },
        },
      },
    },
    async (req, reply) => {
      const { id } = req.params;
      const q = req.query as Record<string, unknown>;
      const live = q["live"] === true || q["live"] === "true";
      const limit = Math.min(Number(q["limit"] ?? 100), 500);
      const from = q["from"] as string | undefined;
      const to = q["to"] as string | undefined;
      const aggregate = q["aggregate"] as string | undefined;

      if (!live) {
        const params: unknown[] = [id, config.network, limit];
        let where = "WHERE party_id = $1 AND network = $2";
        if (from) {
          params.push(from);
          where += ` AND created_at >= $${params.length}`;
        }
        if (to) {
          params.push(to);
          where += ` AND created_at <= $${params.length}`;
        }

        if (aggregate) {
          const truncUnit = aggregate === "day" ? "day" : aggregate === "week" ? "week" : "month";
          const aggRows = await queryRows<{
            period: string;
            total_amount: string;
            round_count: number;
          }>(
            `SELECT
             DATE_TRUNC('${truncUnit}', created_at) AS period,
             SUM(amount)::TEXT                       AS total_amount,
             COUNT(*)::INTEGER                       AS round_count
           FROM rewards ${where}
           GROUP BY DATE_TRUNC('${truncUnit}', created_at)
           ORDER BY period DESC
           LIMIT $3`,
            params,
          );
          if (aggRows.length > 0) {
            const totalAmount = aggRows.reduce(
              (acc, r) => acc + parseFloat(r.total_amount ?? "0"),
              0,
            );
            return reply.send({
              party_id: id,
              network: config.network,
              aggregate,
              total_amount: totalAmount.toFixed(10),
              count: aggRows.length,
              source: "indexed",
              data: aggRows,
            });
          }
        } else {
          const rows = await queryRows<{ round: number; amount: string; created_at: string }>(
            `SELECT round, amount, created_at, captured_at
           FROM rewards ${where}
           ORDER BY round DESC NULLS LAST
           LIMIT $3`,
            params,
          );
          if (rows.length > 0) {
            const totalAmount = rows.reduce((acc, r) => acc + parseFloat(r.amount ?? "0"), 0);
            return reply.send({
              party_id: id,
              network: config.network,
              total_amount: totalAmount.toFixed(10),
              count: rows.length,
              source: "indexed",
              data: rows,
            });
          }
        }
      }

      // Fallback to Lighthouse
      const res = await lighthouse.getPartyRewards(id, { page_size: String(limit) } as never);
      if (!res.ok) {
        return reply.status(502).send({ error: "Upstream unavailable", detail: res.error });
      }
      const data = Array.isArray(res.data) ? res.data : [];
      return reply.send({
        party_id: id,
        network: config.network,
        count: data.length,
        source: "lighthouse",
        data,
      });
    },
  );

  // GET /api/parties/:id/reward-stats
  server.get<{ Params: { id: string } }>(
    "/parties/:id/reward-stats",
    {
      schema: {
        tags: ["parties"],
        summary: "Aggregated reward statistics for a party",
        params: {
          type: "object",
          properties: { id: { type: "string" } },
          required: ["id"],
        },
      },
    },
    async (req, reply) => {
      const { id } = req.params;

      const [dbStats, liveStats] = await Promise.allSettled([
        queryOne<{
          total_amount: string;
          round_count: number;
          first_reward: string;
          last_reward: string;
        }>(
          `SELECT
           SUM(amount)::TEXT  AS total_amount,
           COUNT(*)::INTEGER  AS round_count,
           MIN(created_at)    AS first_reward,
           MAX(created_at)    AS last_reward
         FROM rewards
         WHERE party_id = $1 AND network = $2`,
          [id, config.network],
        ),
        lighthouse.getPartyRewardStats(id),
      ]);

      const db = dbStats.status === "fulfilled" ? dbStats.value : null;
      const live =
        liveStats.status === "fulfilled" && liveStats.value.ok ? liveStats.value.data : null;

      return reply.send({
        party_id: id,
        network: config.network,
        indexed: db
          ? {
              total_amount: db.total_amount,
              round_count: db.round_count,
              first_reward_at: db.first_reward,
              last_reward_at: db.last_reward,
            }
          : null,
        live,
      });
    },
  );

  // GET /api/parties/:id/transfers
  server.get<{ Params: { id: string } }>(
    "/parties/:id/transfers",
    {
      schema: {
        tags: ["parties"],
        summary: "List transfers for a party (sender or receiver)",
        params: {
          type: "object",
          properties: { id: { type: "string" } },
          required: ["id"],
        },
        querystring: {
          type: "object",
          properties: {
            limit: { type: "integer", default: 50, maximum: 500 },
            direction: { type: "string", enum: ["sent", "received", "all"], default: "all" },
            live: { type: "boolean", description: "Force live fetch from Lighthouse" },
          },
        },
      },
    },
    async (req, reply) => {
      const { id } = req.params;
      const q = req.query as Record<string, unknown>;
      const live = q["live"] === true || q["live"] === "true";
      const limit = Math.min(Number(q["limit"] ?? 50), 500);
      const direction = (q["direction"] as string) ?? "all";

      if (!live) {
        let where = "WHERE network = $1";
        const params: unknown[] = [config.network, limit];

        if (direction === "sent") {
          params.push(id);
          where += ` AND sender = $${params.length}`;
        } else if (direction === "received") {
          params.push(id);
          where += ` AND receiver = $${params.length}`;
        } else {
          params.push(id);
          params.push(id);
          where += ` AND (sender = $${params.length - 1} OR receiver = $${params.length})`;
        }

        const rows = await queryRows<Record<string, unknown>>(
          `SELECT id, sender, receiver, amount, created_at, captured_at
         FROM transfers ${where}
         ORDER BY created_at DESC NULLS LAST
         LIMIT $2`,
          params,
        );
        if (rows.length > 0) {
          return reply.send({
            party_id: id,
            network: config.network,
            count: rows.length,
            source: "indexed",
            data: rows,
          });
        }
      }

      const res = await lighthouse.getPartyTransfers(id, { page_size: String(limit) } as never);
      if (!res.ok) {
        return reply.status(502).send({ error: "Upstream unavailable", detail: res.error });
      }
      const data = Array.isArray(res.data) ? res.data : [];
      return reply.send({
        party_id: id,
        network: config.network,
        count: data.length,
        source: "lighthouse",
        data,
      });
    },
  );

  // GET /api/parties/:id/transactions
  server.get<{ Params: { id: string } }>(
    "/parties/:id/transactions",
    {
      schema: {
        tags: ["parties"],
        summary: "List transactions for a party",
        params: {
          type: "object",
          properties: { id: { type: "string" } },
          required: ["id"],
        },
        querystring: {
          type: "object",
          properties: {
            limit: { type: "integer", default: 50, maximum: 500 },
          },
        },
      },
    },
    async (req, reply) => {
      const { id } = req.params;
      const q = req.query as Record<string, unknown>;
      const limit = Math.min(Number(q["limit"] ?? 50), 500);

      const res = await lighthouse.getPartyTransactions(id, { page_size: String(limit) } as never);
      if (!res.ok) {
        return reply.status(502).send({ error: "Upstream unavailable", detail: res.error });
      }
      const data = Array.isArray(res.data) ? res.data : [];
      return reply.send({ party_id: id, network: config.network, count: data.length, data });
    },
  );

  // GET /api/parties/:id/pnl
  server.get<{ Params: { id: string } }>(
    "/parties/:id/pnl",
    {
      schema: {
        tags: ["parties"],
        summary: "Profit/loss data for a party",
        params: {
          type: "object",
          properties: { id: { type: "string" } },
          required: ["id"],
        },
      },
    },
    async (req, reply) => {
      const { id } = req.params;
      const res = await lighthouse.getPartyPnl(id);
      if (!res.ok) {
        return reply.status(502).send({ error: "Upstream unavailable", detail: res.error });
      }
      return reply.send({ party_id: id, network: config.network, data: res.data });
    },
  );

  // GET /api/parties/:id/burns
  server.get<{ Params: { id: string } }>(
    "/parties/:id/burns",
    {
      schema: {
        tags: ["parties"],
        summary: "Burns for a party",
        params: {
          type: "object",
          properties: { id: { type: "string" } },
          required: ["id"],
        },
        querystring: {
          type: "object",
          properties: {
            limit: { type: "integer", default: 50, maximum: 500 },
          },
        },
      },
    },
    async (req, reply) => {
      const { id } = req.params;
      const q = req.query as Record<string, unknown>;
      const limit = Math.min(Number(q["limit"] ?? 50), 500);

      const res = await lighthouse.getPartyBurns(id, { page_size: String(limit) } as never);
      if (!res.ok) {
        return reply.status(502).send({ error: "Upstream unavailable", detail: res.error });
      }
      const data = Array.isArray(res.data) ? res.data : [];
      return reply.send({ party_id: id, network: config.network, count: data.length, data });
    },
  );

  // GET /api/parties/:id/burn-stats
  server.get<{ Params: { id: string } }>(
    "/parties/:id/burn-stats",
    {
      schema: {
        tags: ["parties"],
        summary: "Aggregated burn statistics for a party",
        params: {
          type: "object",
          properties: { id: { type: "string" } },
          required: ["id"],
        },
      },
    },
    async (req, reply) => {
      const { id } = req.params;
      const res = await lighthouse.getPartyBurnStats(id);
      if (!res.ok) {
        return reply.status(502).send({ error: "Upstream unavailable", detail: res.error });
      }
      return reply.send({ party_id: id, network: config.network, data: res.data });
    },
  );

  // GET /api/rewards/leaderboard — custom: top earners ranking
  server.get(
    "/rewards/leaderboard",
    {
      schema: {
        tags: ["parties"],
        summary: "Top reward earners leaderboard",
        description:
          "Rankings based on indexed reward history. Requires data to have been collected.",
        querystring: {
          type: "object",
          properties: {
            limit: { type: "integer", default: 20, maximum: 100 },
            from: { type: "string", description: "ISO8601 start date" },
            to: { type: "string", description: "ISO8601 end date" },
          },
        },
      },
    },
    async (req, reply) => {
      const q = req.query as Record<string, unknown>;
      const limit = Math.min(Number(q["limit"] ?? 20), 100);
      const from = q["from"] as string | undefined;
      const to = q["to"] as string | undefined;

      const params: unknown[] = [config.network, limit];
      let where = "WHERE network = $1";
      if (from) {
        params.push(from);
        where += ` AND created_at >= $${params.length}`;
      }
      if (to) {
        params.push(to);
        where += ` AND created_at <= $${params.length}`;
      }

      const rows = await queryRows<{
        party_id: string;
        total_amount: string;
        round_count: number;
        last_reward_at: string;
      }>(
        `SELECT
         party_id,
         SUM(amount)::TEXT  AS total_amount,
         COUNT(*)::INTEGER  AS round_count,
         MAX(created_at)    AS last_reward_at
       FROM rewards ${where}
       GROUP BY party_id
       ORDER BY SUM(amount) DESC NULLS LAST
       LIMIT $2`,
        params,
      );

      return reply.send({
        network: config.network,
        count: rows.length,
        data: rows.map((r, i) => ({ rank: i + 1, ...r })),
      });
    },
  );
}
