import { FastifyInstance } from "fastify";
import { queryRows, queryOne } from "../../storage/db.js";
import { lighthouse } from "../../collectors/lighthouse.js";
import { config } from "../../config.js";

export async function registerValidatorRoutes(server: FastifyInstance): Promise<void> {
  // GET /api/validators
  server.get(
    "/validators",
    {
      schema: {
        tags: ["validators"],
        summary: "List all validators",
        querystring: {
          type: "object",
          properties: {
            live: { type: "boolean", description: "Force live fetch" },
            limit: { type: "integer", default: 100, maximum: 500 },
          },
        },
      },
    },
    async (req, reply) => {
      const q = req.query as Record<string, unknown>;
      const live = q["live"] === true || q["live"] === "true";
      const limit = Math.min(Number(q["limit"] ?? 100), 500);

      if (!live) {
        const rows = await queryRows<Record<string, unknown>>(
          `SELECT id, name, party_id, is_active, version, first_seen_at, last_seen_at
           FROM validators
           WHERE network = $1
           ORDER BY last_seen_at DESC
           LIMIT $2`,
          [config.network, limit],
        );
        if (rows.length > 0) {
          return reply.send({ network: config.network, count: rows.length, data: rows });
        }
      }

      const res = await lighthouse.getValidators({ page_size: limit });
      if (!res.ok) {
        return reply.status(502).send({ error: "Upstream unavailable", detail: res.error });
      }
      return reply.send({
        network: config.network,
        count: res.data.count,
        data: res.data.validators,
      });
    },
  );

  // GET /api/validators/:id
  server.get<{ Params: { id: string } }>(
    "/validators/:id",
    {
      schema: {
        tags: ["validators"],
        summary: "Get validator by ID",
        params: {
          type: "object",
          properties: { id: { type: "string" } },
          required: ["id"],
        },
        querystring: {
          type: "object",
          properties: {
            live: { type: "boolean", description: "Force live fetch" },
          },
        },
      },
    },
    async (req, reply) => {
      const { id } = req.params;
      const q = req.query as Record<string, unknown>;
      const live = q["live"] === true || q["live"] === "true";

      if (!live) {
        const row = await queryOne<Record<string, unknown>>(
          `SELECT id, name, party_id, is_active, version, first_seen_at, last_seen_at, raw
           FROM validators
           WHERE id = $1 AND network = $2`,
          [id, config.network],
        );
        if (row) return reply.send(row);
      }

      const res = await lighthouse.getValidator(id);
      if (!res.ok) {
        const status = res.status === 404 ? 404 : 502;
        return reply.status(status).send({
          error: res.status === 404 ? "Not found" : "Upstream unavailable",
          detail: res.error,
        });
      }
      // Real response: {validator: {...}, balance: {...}, traffic_status: ...}
      return reply.send({ ...res.data, network: config.network });
    },
  );

  // GET /api/validators/:id/uptime
  server.get<{ Params: { id: string } }>(
    "/validators/:id/uptime",
    {
      schema: {
        tags: ["validators"],
        summary: "Validator uptime history (snapshots)",
        params: {
          type: "object",
          properties: { id: { type: "string" } },
          required: ["id"],
        },
        querystring: {
          type: "object",
          properties: {
            limit: { type: "integer", default: 96, maximum: 500 },
            from: { type: "string", description: "ISO8601 start date" },
            to: { type: "string", description: "ISO8601 end date" },
          },
        },
      },
    },
    async (req, reply) => {
      const { id } = req.params;
      const q = req.query as Record<string, unknown>;
      const limit = Math.min(Number(q["limit"] ?? 96), 500);
      const from = q["from"] as string | undefined;
      const to = q["to"] as string | undefined;

      const params: unknown[] = [id, config.network, limit];
      let where = "WHERE validator_id = $1 AND network = $2";
      if (from) {
        params.push(from);
        where += ` AND captured_at >= $${params.length}`;
      }
      if (to) {
        params.push(to);
        where += ` AND captured_at <= $${params.length}`;
      }

      const rows = await queryRows<{ is_active: boolean; captured_at: string }>(
        `SELECT is_active, captured_at
         FROM validator_snapshots ${where}
         ORDER BY captured_at DESC
         LIMIT $3`,
        params,
      );

      const total = rows.length;
      const activeCount = rows.filter((r) => r.is_active).length;
      const uptimePct = total > 0 ? ((activeCount / total) * 100).toFixed(2) : null;

      return reply.send({
        validator_id: id,
        network: config.network,
        total_snapshots: total,
        active_snapshots: activeCount,
        uptime_pct: uptimePct ? parseFloat(uptimePct) : null,
        data: rows,
      });
    },
  );

  // GET /api/validators/:id/rewards/history
  server.get<{ Params: { id: string } }>(
    "/validators/:id/rewards/history",
    {
      schema: {
        tags: ["validators"],
        summary: "Historical reward tracking for a validator",
        description:
          "Persisted reward history. Rewards are indexed when party/:id/rewards is polled. Three reward types: app_reward, validator_reward, sv_reward.",
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
          },
        },
      },
    },
    async (req, reply) => {
      const { id } = req.params;
      const q = req.query as Record<string, unknown>;
      const limit = Math.min(Number(q["limit"] ?? 100), 500);
      const from = q["from"] as string | undefined;
      const to = q["to"] as string | undefined;

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

      const rows = await queryRows<{
        round: number;
        app_reward: string;
        validator_reward: string;
        sv_reward: string;
        created_at: string;
      }>(
        `SELECT round, app_reward, validator_reward, sv_reward, created_at, captured_at
         FROM rewards ${where}
         ORDER BY round DESC NULLS LAST
         LIMIT $3`,
        params,
      );

      const totalValidator = rows.reduce(
        (acc, r) => acc + parseFloat(r.validator_reward ?? "0"),
        0,
      );
      const totalApp = rows.reduce((acc, r) => acc + parseFloat(r.app_reward ?? "0"), 0);
      const totalSv = rows.reduce((acc, r) => acc + parseFloat(r.sv_reward ?? "0"), 0);

      return reply.send({
        party_id: id,
        network: config.network,
        totals: {
          validator_reward: totalValidator.toFixed(10),
          app_reward: totalApp.toFixed(10),
          sv_reward: totalSv.toFixed(10),
        },
        count: rows.length,
        data: rows,
      });
    },
  );
}
