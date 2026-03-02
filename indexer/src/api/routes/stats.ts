import { FastifyInstance } from "fastify";
import { queryRows, queryOne } from "../../storage/db.js";
import { lighthouse } from "../../collectors/lighthouse.js";
import { config } from "../../config.js";

export async function registerStatsRoutes(server: FastifyInstance): Promise<void> {
  // GET /api/stats
  server.get(
    "/stats",
    {
      schema: {
        tags: ["stats"],
        summary: "Latest network statistics",
        querystring: {
          type: "object",
          properties: {
            live: { type: "boolean", description: "Force live fetch from Lighthouse" },
          },
        },
      },
    },
    async (req, reply) => {
      const live =
        (req.query as Record<string, unknown>)["live"] === true ||
        (req.query as Record<string, unknown>)["live"] === "true";

      if (!live) {
        const row = await queryOne<{ raw: unknown; captured_at: string; cc_price: string | null }>(
          `SELECT raw, captured_at, cc_price
           FROM stats_snapshots
           WHERE network = $1
           ORDER BY captured_at DESC
           LIMIT 1`,
          [config.network],
        );
        if (row) {
          return reply.send({
            ...(row.raw as object),
            _cached_at: row.captured_at,
            network: config.network,
          });
        }
      }

      const res = await lighthouse.getStats();
      if (!res.ok) {
        return reply.status(502).send({ error: "Upstream unavailable", detail: res.error });
      }
      return reply.send({ ...res.data, network: config.network });
    },
  );

  // GET /api/stats/history
  server.get(
    "/stats/history",
    {
      schema: {
        tags: ["stats"],
        summary: "Historical network stats snapshots",
        querystring: {
          type: "object",
          properties: {
            limit: { type: "integer", default: 48, maximum: 200 },
            from: { type: "string", description: "ISO8601 start date" },
            to: { type: "string", description: "ISO8601 end date" },
          },
        },
      },
    },
    async (req, reply) => {
      const q = req.query as Record<string, unknown>;
      const limit = Math.min(Number(q["limit"] ?? 48), 200);
      const from = q["from"] as string | undefined;
      const to = q["to"] as string | undefined;

      const params: unknown[] = [config.network, limit];
      let where = "WHERE network = $1";
      if (from) {
        params.push(from);
        where += ` AND captured_at >= $${params.length}`;
      }
      if (to) {
        params.push(to);
        where += ` AND captured_at <= $${params.length}`;
      }

      const rows = await queryRows<{
        total_validators: number;
        cc_price: string | null;
        captured_at: string;
      }>(
        `SELECT total_validators, cc_price, captured_at
         FROM stats_snapshots ${where}
         ORDER BY captured_at DESC
         LIMIT $2`,
        params,
      );

      return reply.send({ network: config.network, count: rows.length, data: rows });
    },
  );

  // GET /api/prices/latest — extracted from stats (no separate prices endpoint in Lighthouse)
  server.get(
    "/prices/latest",
    {
      schema: {
        tags: ["stats"],
        summary: "Latest CC price in USD (extracted from network stats)",
        querystring: {
          type: "object",
          properties: {
            live: { type: "boolean", description: "Force live fetch from Lighthouse" },
          },
        },
      },
    },
    async (req, reply) => {
      const live =
        (req.query as Record<string, unknown>)["live"] === true ||
        (req.query as Record<string, unknown>)["live"] === "true";

      if (!live) {
        const row = await queryOne<{ price_usd: string; captured_at: string }>(
          `SELECT price_usd, captured_at
           FROM prices
           WHERE network = $1
           ORDER BY captured_at DESC
           LIMIT 1`,
          [config.network],
        );
        if (row) {
          return reply.send({
            price_usd: row.price_usd,
            _cached_at: row.captured_at,
            network: config.network,
          });
        }
      }

      // Fallback: fetch from stats
      const res = await lighthouse.getStats();
      if (!res.ok) {
        return reply.status(502).send({ error: "Upstream unavailable", detail: res.error });
      }
      return reply.send({
        price_usd: res.data.cc_price ?? null,
        network: config.network,
        source: "stats",
      });
    },
  );

  // GET /api/prices/history — persisted from stats polling
  server.get(
    "/prices/history",
    {
      schema: {
        tags: ["stats"],
        summary: "CC price history (persisted from periodic stats polling)",
        description:
          "Lighthouse has no dedicated prices endpoint. Price is extracted from /api/stats cc_price field and persisted on each poll cycle.",
        querystring: {
          type: "object",
          properties: {
            limit: {
              type: "integer",
              default: 144,
              maximum: 2000,
              description: "Number of data points",
            },
            from: { type: "string", description: "ISO8601 start date" },
            to: { type: "string", description: "ISO8601 end date" },
          },
        },
      },
    },
    async (req, reply) => {
      const q = req.query as Record<string, unknown>;
      const limit = Math.min(Number(q["limit"] ?? 144), 2000);
      const from = q["from"] as string | undefined;
      const to = q["to"] as string | undefined;

      const params: unknown[] = [config.network, limit];
      let where = "WHERE network = $1";
      if (from) {
        params.push(from);
        where += ` AND captured_at >= $${params.length}`;
      }
      if (to) {
        params.push(to);
        where += ` AND captured_at <= $${params.length}`;
      }

      const rows = await queryRows<{ price_usd: string; captured_at: string }>(
        `SELECT price_usd, captured_at
         FROM prices ${where}
         ORDER BY captured_at DESC
         LIMIT $2`,
        params,
      );

      if (rows.length === 0) {
        return reply.send({
          network: config.network,
          count: 0,
          message: "No price history yet — prices are collected on each stats poll cycle",
          data: [],
        });
      }

      const prices = rows.map((r) => parseFloat(r.price_usd));
      const minPrice = Math.min(...prices);
      const maxPrice = Math.max(...prices);
      const avgPrice = prices.reduce((a, b) => a + b, 0) / prices.length;
      const firstPrice = prices[prices.length - 1]!;
      const lastPrice = prices[0]!;
      const changePct =
        firstPrice > 0 ? (((lastPrice - firstPrice) / firstPrice) * 100).toFixed(4) : null;

      return reply.send({
        network: config.network,
        count: rows.length,
        stats: {
          min_usd: minPrice.toFixed(8),
          max_usd: maxPrice.toFixed(8),
          avg_usd: avgPrice.toFixed(8),
          change_pct: changePct ? parseFloat(changePct) : null,
          from_date: rows[rows.length - 1]?.captured_at ?? null,
          to_date: rows[0]?.captured_at ?? null,
        },
        data: rows,
      });
    },
  );
}
