import Fastify, { FastifyInstance } from "fastify";
import cors from "@fastify/cors";
import swagger from "@fastify/swagger";
import swaggerUi from "@fastify/swagger-ui";
import { config } from "../config.js";
import { checkConnection, migrate } from "../storage/db.js";
import { registerStatsRoutes } from "./routes/stats.js";
import { registerValidatorRoutes } from "./routes/validators.js";
import { registerTransactionRoutes } from "./routes/transactions.js";
import { registerTransferRoutes } from "./routes/transfers.js";
import { registerGovernanceRoutes } from "./routes/governance.js";
import { registerPartyRoutes } from "./routes/parties.js";
import { registerRoundRoutes } from "./routes/rounds.js";
import { registerMiscRoutes } from "./routes/misc.js";

export async function buildServer(): Promise<FastifyInstance> {
  const server = Fastify({
    logger: {
      level: config.server.logLevel,
      transport:
        process.env["NODE_ENV"] !== "production"
          ? { target: "pino-pretty", options: { colorize: true } }
          : undefined,
    },
  });

  // ── Plugins ───────────────────────────────────────────────────────────────

  await server.register(cors, { origin: true });

  await server.register(swagger, {
    openapi: {
      info: {
        title: "Canton Network Indexer API",
        description:
          "Unified REST API for Canton Network — aggregates Lighthouse Explorer, Scan API, Validator and Participant data with historical persistence.",
        version: "0.1.0",
      },
      servers: [
        { url: `http://${config.server.host}:${config.server.port}`, description: "Local" },
      ],
      tags: [
        { name: "stats", description: "Network statistics" },
        { name: "validators", description: "Validator data" },
        { name: "parties", description: "Party data (balance, rewards, transactions)" },
        { name: "transactions", description: "Transactions" },
        { name: "transfers", description: "Transfers" },
        { name: "rounds", description: "Consensus rounds" },
        { name: "governance", description: "Governance votes" },
        { name: "prices", description: "CC price" },
        { name: "misc", description: "CNS, featured apps, preapprovals, search" },
      ],
    },
  });

  await server.register(swaggerUi, {
    routePrefix: "/docs",
    uiConfig: { docExpansion: "list", deepLinking: true },
  });

  // ── Routes ────────────────────────────────────────────────────────────────

  server.get(
    "/health",
    {
      schema: {
        summary: "Health check",
        response: {
          200: {
            type: "object",
            properties: {
              status: { type: "string" },
              network: { type: "string" },
              db: { type: "boolean" },
              uptime: { type: "number" },
            },
          },
        },
      },
    },
    async (_req, reply) => {
      const db = await checkConnection();
      return reply.send({
        status: db ? "ok" : "degraded",
        network: config.network,
        db,
        uptime: process.uptime(),
      });
    },
  );

  await server.register(registerStatsRoutes, { prefix: "/api" });
  await server.register(registerValidatorRoutes, { prefix: "/api" });
  await server.register(registerPartyRoutes, { prefix: "/api" });
  await server.register(registerTransactionRoutes, { prefix: "/api" });
  await server.register(registerTransferRoutes, { prefix: "/api" });
  await server.register(registerRoundRoutes, { prefix: "/api" });
  await server.register(registerGovernanceRoutes, { prefix: "/api" });
  await server.register(registerMiscRoutes, { prefix: "/api" });

  return server;
}

export async function startServer(): Promise<void> {
  const server = await buildServer();

  await migrate();

  try {
    await server.listen({ host: config.server.host, port: config.server.port });
    console.log(`[server] listening on ${config.server.host}:${config.server.port}`);
    console.log(`[server] docs at http://localhost:${config.server.port}/docs`);
  } catch (err) {
    server.log.error(err);
    process.exit(1);
  }

  const shutdown = async (signal: string) => {
    console.log(`[server] ${signal} received, shutting down`);
    await server.close();
    process.exit(0);
  };

  process.on("SIGTERM", () => shutdown("SIGTERM"));
  process.on("SIGINT", () => shutdown("SIGINT"));
}
