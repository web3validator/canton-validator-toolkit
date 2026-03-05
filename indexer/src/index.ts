import { startServer } from './api/server.js';
import { startScheduler } from './scheduler.js';
import { checkConnection } from './storage/db.js';

async function main(): Promise<void> {
  console.log('[main] Canton Network Indexer starting...');
  console.log(`[main] network: ${process.env['CANTON_NETWORK'] ?? 'mainnet'}`);

  // Wait for DB to be ready (retry up to 30s)
  let dbReady = false;
  for (let i = 0; i < 15; i++) {
    dbReady = await checkConnection();
    if (dbReady) break;
    console.log(`[main] waiting for database... (${i + 1}/15)`);
    await new Promise((r) => setTimeout(r, 2000));
  }

  if (!dbReady) {
    console.error('[main] database not reachable after 30s — exiting');
    process.exit(1);
  }

  console.log('[main] database connected');

  startScheduler();
  await startServer();
}

main().catch((err) => {
  console.error('[main] fatal error', err);
  process.exit(1);
});
