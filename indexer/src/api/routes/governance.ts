import { FastifyInstance } from 'fastify';
import { queryRows, queryOne } from '../../storage/db.js';
import { lighthouse } from '../../collectors/lighthouse.js';
import { config } from '../../config.js';

export async function registerGovernanceRoutes(server: FastifyInstance): Promise<void> {
  // GET /api/governance
  server.get('/governance', {
    schema: {
      tags: ['governance'],
      summary: 'List governance vote requests',
      querystring: {
        type: 'object',
        properties: {
          limit: { type: 'integer', default: 50, maximum: 500 },
          live:  { type: 'boolean', description: 'Force live fetch from Lighthouse' },
        },
      },
    },
  }, async (req, reply) => {
    const q = req.query as Record<string, unknown>;
    const live  = q['live'] === true || q['live'] === 'true';
    const limit = Math.min(Number(q['limit'] ?? 50), 500);

    if (!live) {
      const rows = await queryRows<Record<string, unknown>>(
        `SELECT id, captured_at, raw
         FROM governance_votes
         WHERE network = $1
         ORDER BY captured_at DESC
         LIMIT $2`,
        [config.network, limit],
      );
      if (rows.length > 0) {
        return reply.send({ network: config.network, count: rows.length, source: 'indexed', data: rows });
      }
    }

    const res = await lighthouse.getGovernanceVotes({ page_size: String(limit) } as never);
    if (!res.ok) {
      return reply.status(502).send({ error: 'Upstream unavailable', detail: res.error });
    }
    const data = Array.isArray(res.data) ? res.data : [];
    return reply.send({ network: config.network, count: data.length, source: 'lighthouse', data });
  });

  // GET /api/governance/stats
  server.get('/governance/stats', {
    schema: {
      tags: ['governance'],
      summary: 'Governance statistics snapshot',
      querystring: {
        type: 'object',
        properties: {
          live: { type: 'boolean', description: 'Force live fetch from Lighthouse' },
        },
      },
    },
  }, async (req, reply) => {
    const q = req.query as Record<string, unknown>;
    const live = q['live'] === true || q['live'] === 'true';

    if (!live) {
      const row = await queryOne<{ raw: unknown; captured_at: string }>(
        `SELECT raw, captured_at
         FROM governance_stats_snapshots
         WHERE network = $1
         ORDER BY captured_at DESC
         LIMIT 1`,
        [config.network],
      );
      if (row) {
        return reply.send({ ...row.raw as object, _cached_at: row.captured_at });
      }
    }

    const res = await lighthouse.getGovernanceStats();
    if (!res.ok) {
      return reply.status(502).send({ error: 'Upstream unavailable', detail: res.error });
    }
    return reply.send(res.data);
  });

  // GET /api/governance/:id
  server.get<{ Params: { id: string } }>('/governance/:id', {
    schema: {
      tags: ['governance'],
      summary: 'Get governance vote request by ID',
      params: {
        type: 'object',
        properties: { id: { type: 'string' } },
        required: ['id'],
      },
    },
  }, async (req, reply) => {
    const { id } = req.params;

    const row = await queryOne<Record<string, unknown>>(
      `SELECT id, captured_at, raw
       FROM governance_votes
       WHERE id = $1 AND network = $2`,
      [id, config.network],
    );
    if (row) return reply.send(row);

    const res = await lighthouse.getGovernanceVote(id);
    if (!res.ok) {
      const status = res.status === 404 ? 404 : 502;
      return reply.status(status).send({
        error: res.status === 404 ? 'Not found' : 'Upstream unavailable',
        detail: res.error,
      });
    }
    return reply.send(res.data);
  });
}
