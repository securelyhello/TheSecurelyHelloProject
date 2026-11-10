import { createApp, loadConfig } from './app.js';
import { createPool } from './db.js';
import { createRedis } from './hotstore.js';
import { logger } from './log.js';
import { migrate } from './migrate.js';

const config = loadConfig();
const pool = createPool(process.env.DATABASE_URL, {
  max: Number.parseInt(process.env.DB_POOL_MAX ?? '10', 10) || 10,
});
const redis = createRedis(process.env.REDIS_URL);
redis.on('error', (err) => logger.warn('redis error', { error: err.message }));

try {
  if (process.env.MIGRATE_ON_START === '1') {
    const migrationUrl = process.env.MIGRATION_DATABASE_URL;
    if (migrationUrl) {
      const mpool = createPool(migrationUrl, { max: 1 });
      try {
        await migrate(mpool);
      } finally {
        await mpool.end();
      }
    } else {
      await migrate(pool);
    }
  }
  // Fail fast if the schema is missing or Redis is unreachable.
  await pool.query('SELECT 1 FROM users LIMIT 1');
  await redis.ping();
} catch (err) {
  logger.error('startup failed (is the database migrated and Redis reachable?)', { error: err.message });
  process.exit(1);
}

const app = createApp({ pool, redis, config });
const addr = await app.listen();
logger.info('listening', { host: addr.address, port: addr.port, ws: '/api/ws', trustProxyHops: config.trustProxyHops });

let stopping = false;
async function shutdown(signal) {
  if (stopping) return;
  stopping = true;
  logger.info('shutdown', { signal });
  const force = setTimeout(() => process.exit(1), 15_000);
  force.unref();
  await app.close().catch(() => {});
  await pool.end().catch(() => {});
  await redis.quit().catch(() => {});
  process.exit(0);
}
process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));
