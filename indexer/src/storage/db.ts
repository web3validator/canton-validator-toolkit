import { Pool, PoolClient, QueryResult, QueryResultRow } from "pg";
import { config } from "../config.js";

const poolConfig = config.db.connectionString
  ? { connectionString: config.db.connectionString, max: config.db.poolMax }
  : {
      host: config.db.host,
      port: config.db.port,
      database: config.db.name,
      user: config.db.user,
      password: config.db.password,
      max: config.db.poolMax,
    };

export const pool = new Pool(poolConfig);

pool.on("error", (err) => {
  console.error("[db] unexpected pool error", err);
});

export async function query<T extends QueryResultRow = QueryResultRow>(
  sql: string,
  params?: unknown[],
): Promise<QueryResult<T>> {
  return pool.query<T>(sql, params);
}

export async function queryRows<T extends QueryResultRow = QueryResultRow>(
  sql: string,
  params?: unknown[],
): Promise<T[]> {
  const result = await pool.query<T>(sql, params);
  return result.rows;
}

export async function queryOne<T extends QueryResultRow = QueryResultRow>(
  sql: string,
  params?: unknown[],
): Promise<T | null> {
  const result = await pool.query<T>(sql, params);
  return result.rows[0] ?? null;
}

export async function withTransaction<T>(fn: (client: PoolClient) => Promise<T>): Promise<T> {
  const client = await pool.connect();
  try {
    await client.query("BEGIN");
    const result = await fn(client);
    await client.query("COMMIT");
    return result;
  } catch (err) {
    await client.query("ROLLBACK");
    throw err;
  } finally {
    client.release();
  }
}

export async function migrate(): Promise<void> {
  const { readFileSync } = await import("fs");
  const { join } = await import("path");

  const schemaPath = join(__dirname, "schema.sql");
  const sql = readFileSync(schemaPath, "utf8");

  const client = await pool.connect();
  try {
    await client.query(sql);
    console.log("[db] schema applied");
  } finally {
    client.release();
  }
}

export async function checkConnection(): Promise<boolean> {
  try {
    await pool.query("SELECT 1");
    return true;
  } catch {
    return false;
  }
}
