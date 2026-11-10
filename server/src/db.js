import pg from 'pg';

/**
 * Builds a pg Pool config from a DATABASE_URL.
 *
 * TLS is used when the URL asks for it (`sslmode=require|verify-ca|verify-full`,
 * as in every Neon connection string) or when the host is a Neon endpoint.
 * Certificates are always verified. `sslmode=disable` (or no sslmode on a
 * non-Neon host, e.g. local Docker) connects without TLS.
 */
export function poolConfigFromUrl(databaseUrl, { max = 10 } = {}) {
  if (!databaseUrl) {
    throw new Error('DATABASE_URL is not set (see server/.env.example)');
  }
  const url = new URL(databaseUrl);
  const sslmode = url.searchParams.get('sslmode');
  const isNeon = url.hostname.endsWith('.neon.tech');
  // Let us, not pg-connection-string, decide on TLS; drop libpq-only params
  // that node-postgres does not understand.
  for (const p of ['sslmode', 'channel_binding', 'sslrootcert', 'sslcert', 'sslkey']) {
    url.searchParams.delete(p);
  }
  const wantSsl = sslmode ? sslmode !== 'disable' && sslmode !== 'allow' && sslmode !== 'prefer' : isNeon;
  return {
    connectionString: url.toString(),
    ssl: wantSsl ? { rejectUnauthorized: true } : false,
    max,
    idleTimeoutMillis: 30_000,
    connectionTimeoutMillis: 15_000,
  };
}

export function createPool(databaseUrl, opts) {
  const pool = new pg.Pool(poolConfigFromUrl(databaseUrl, opts));
  // An idle client erroring (e.g. Neon scaling to zero) must not crash us.
  pool.on('error', (err) => console.error('[db] idle client error:', err.message));
  return pool;
}

/** Runs [fn] inside a transaction on one pooled client. */
export async function withTransaction(pool, fn) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const result = await fn(client);
    await client.query('COMMIT');
    return result;
  } catch (err) {
    try {
      await client.query('ROLLBACK');
    } catch {
      /* connection already broken */
    }
    throw err;
  } finally {
    client.release();
  }
}
