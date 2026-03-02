import { FastifyInstance } from 'fastify';
import { queryRows } from '../../storage/db.js';
import { lighthouse } from '../../collectors/lighthouse.js';
import { config } from '../../config.js';

export async function registerTransferRoutes(server: FastifyInstance): Promise<void> {
  // GET /api/transfers
  server.get('/transfers', {
    schema: {
      tags: ['transfers'],
      summary: 'List transfers',
      description: 'Returns persisted transfers from DB with date range filtering. Note: GET /api/transfers/:id is not implemented — known Lighthouse API bug (HTTP 500).',
      querystring: {
        type: 'object',
        properties: {
          limit:    { type: 'integer', default: 50, maximum: 500 },
          from:     { type: 'string', description: 'ISO8601 start date' },
          to:       { type: 'string', description: 'ISO8601 end date' },
          sender:   { type: 'string', description: 'Filter by sender party ID' },
          receiver: { type: 'string', description: 'Filter by receiver party ID' },
          live:     { type: 'boolean', description: 'Force live fetch from Lighthouse' },
        },
      },
    },
  }, async (req, reply) => {
    const q = req.query as Record<string, unknown>;
    const live     = q['live'] === true || q['live'] === 'true';
    const limit    = Math.min(Number(q['limit'] ?? 50), 500);
    const from     = q['from']     as string | undefined;
    const to       = q['to']       as string | undefined;
    const sender   = q['sender']   as string | undefined;
    const receiver = q['receiver'] as string | undefined;

    if (!live) {
      const params: unknown[] = [config.network, limit];
      let where = 'WHERE network = $1';

      if (from)     { params.push(from);     where += ` AND created_at >= $${params.length}`; }
      if (to)       { params.push(to);       where += ` AND created_at <= $${params.length}`; }
      if (sender)   { params.push(sender);   where += ` AND sender = $${params.length}`; }
      if (receiver) { params.push(receiver); where += ` AND receiver = $${params.length}`; }

      const rows = await queryRows<Record<string, unknown>>(
        `SELECT id, sender, receiver, amount, created_at, captured_at
         FROM transfers ${where}
         ORDER BY created_at DESC NULLS LAST
         LIMIT $2`,
        params,
      );

      if (rows.length > 0) {
        return reply.send({ network: config.network, count: rows.length, source: 'indexed', data: rows });
      }
    }

    const res = await lighthouse.getTransfers({ page_size: String(limit) } as never);
    if (!res.ok) {
      return reply.status(502).send({ error: 'Upstream unavailable', detail: res.error });
    }
    const data = Array.isArray(res.data) ? res.data : [];
    return reply.send({ network: config.network, count: data.length, source: 'lighthouse', data });
  });
}
