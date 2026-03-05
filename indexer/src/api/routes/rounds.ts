import { FastifyInstance } from 'fastify';
import { queryRows, queryOne } from '../../storage/db.js';
import { lighthouse } from '../../collectors/lighthouse.js';
import { config } from '../../config.js';

export async function registerRoundRoutes(server: FastifyInstance): Promise<void> {
  // GET /api/rounds
  server.get('/rounds', {
    schema: {
      tags: ['rounds'],
      summary: 'List consensus rounds',
      querystring: {
        type: 'object',
        properties: {
          limit: { type: 'integer', default: 50, maximum: 500 },
          from:  { type: 'string', description: 'ISO8601 start date' },
          to:    { type: 'string', description: 'ISO8601 end date' },
          live:  { type: 'boolean', description: 'Force live fetch from Lighthouse' },
        },
      },
    },
  }, async (req, reply) => {
    const q = req.query as Record<string, unknown>;
    const live  = q['live'] === true || q['live'] === 'true';
    const limit = Math.min(Number(q['limit'] ?? 50), 500);
    const from  = q['from'] as string | undefined;
    const to    = q['to']   as string | undefined;

    if (!live) {
      const params: unknown[] = [config.network, limit];
      let where = 'WHERE network = $1';
      if (from) { params.push(from); where += ` AND created_at >= $${params.length}`; }
      if (to)   { params.push(to);   where += ` AND created_at <= $${params.length}`; }

      const rows = await queryRows<Record<string, unknown>>(
        `SELECT round, created_at, captured_at, raw
         FROM rounds ${where}
         ORDER BY round DESC
         LIMIT $2`,
        params,
      );
      if (rows.length > 0) {
        return reply.send({ network: config.network, count: rows.length, source: 'indexed', data: rows });
      }
    }

    const res = await lighthouse.getRounds({ page_size: String(limit) } as never);
    if (!res.ok) {
      return reply.status(502).send({ error: 'Upstream unavailable', detail: res.error });
    }
    const data = Array.isArray(res.data) ? res.data : [];
    return reply.send({ network: config.network, count: data.length, source: 'lighthouse', data });
  });

  // GET /api/rounds/:number
  server.get<{ Params: { number: string } }>('/rounds/:number', {
    schema: {
      tags: ['rounds'],
      summary: 'Get round by number',
      params: {
        type: 'object',
        properties: { number: { type: 'string' } },
        required: ['number'],
      },
    },
  }, async (req, reply) => {
    const roundNum = parseInt(req.params.number, 10);
    if (isNaN(roundNum)) {
      return reply.status(400).send({ error: 'Invalid round number' });
    }

    const row = await queryOne<Record<string, unknown>>(
      `SELECT round, created_at, captured_at, raw
       FROM rounds WHERE round = $1 AND network = $2`,
      [roundNum, config.network],
    );
    if (row) return reply.send(row);

    const res = await lighthouse.getRound(roundNum);
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
