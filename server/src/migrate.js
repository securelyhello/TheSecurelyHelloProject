// Applies server/migrations/*.sql in filename order, once each.
//
//   npm run migrate                      (local; reads server/.env)
//   docker compose run --rm app node src/migrate.js   (production, one-off)
//
// Uses MIGRATION_DATABASE_URL if set (e.g. Neon's direct, non-pooled
// endpoint), otherwise DATABASE_URL.
//
// Idempotent and safe to run concurrently (e.g. MIGRATE_ON_START on several
// containers): everything happens in ONE transaction guarded by a
// transaction-scoped advisory lock, so it also works through a PgBouncer /
// Neon pooled endpoint in transaction mode, and a failure leaves no partial
// state. Applied files are recorded in schema_migrations.
import { readdir, readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { createPool } from './db.js';
import { logger } from './log.js';

const MIGRATIONS_DIR = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'migrations');
const LOCK_KEY = 72_616_853; // arbitrary, app-specific

export async function migrate(pool, { log = (msg) => logger.info(msg) } = {}) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SELECT pg_advisory_xact_lock($1)', [LOCK_KEY]);
    await client.query(`
      CREATE TABLE IF NOT EXISTS schema_migrations (
        name       text        PRIMARY KEY,
        applied_at timestamptz NOT NULL DEFAULT now()
      )`);
    const { rows } = await client.query('SELECT name FROM schema_migrations');
    const applied = new Set(rows.map((r) => r.name));

    const files = (await readdir(MIGRATIONS_DIR)).filter((f) => f.endsWith('.sql')).sort();
    const done = [];
    for (const file of files) {
      if (applied.has(file)) continue;
      const sql = await readFile(path.join(MIGRATIONS_DIR, file), 'utf8');
      try {
        await client.query(sql);
      } catch (err) {
        throw new Error(`Migration ${file} failed: ${err.message}`);
      }
      await client.query('INSERT INTO schema_migrations (name) VALUES ($1)', [file]);
      done.push(file);
    }
    await client.query('COMMIT');
    for (const f of done) log(`migrate: applied ${f}`);
    if (done.length === 0) log('migrate: database is up to date');
    return done.length;
  } catch (err) {
    await client.query('ROLLBACK').catch(() => {});
    throw err;
  } finally {
    client.release();
  }
}

const isMain = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) {
  const pool = createPool(process.env.MIGRATION_DATABASE_URL || process.env.DATABASE_URL, { max: 1 });
  migrate(pool)
    .then(() => pool.end())
    .catch(async (err) => {
      logger.error('migrate: failed', { error: err.message });
      await pool.end().catch(() => {});
      process.exit(1);
    });
}
