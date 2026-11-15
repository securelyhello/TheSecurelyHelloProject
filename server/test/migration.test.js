import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { after, before, describe, test } from 'node:test';

import { loadConfig } from '../src/app.js';
import { createPool } from '../src/db.js';
import { migrate } from '../src/migrate.js';
import { TEST_DATABASE_URL, fakeKey, recreateDatabase } from './helpers.js';

describe('migration 002_email_tokens', () => {
  let pool;
  before(async () => {
    await recreateDatabase(TEST_DATABASE_URL);
    pool = createPool(TEST_DATABASE_URL, { max: 2 });
  });
  after(() => pool.end());

  test('applies on top of a database that only has 001', async () => {
    const sql = await readFile(new URL('../migrations/001_init.sql', import.meta.url), 'utf8');
    await pool.query(sql);
    await pool.query('CREATE TABLE schema_migrations (name text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())');
    await pool.query(`INSERT INTO schema_migrations (name) VALUES ('001_init.sql')`);
    const { rows } = await pool.query(
      `INSERT INTO users (email, username, password_hash, signing_public_key, encryption_public_key)
       VALUES ('old@example.test', 'old_user', 'x', $1, $2) RETURNING id`,
      [fakeKey(), fakeKey()],
    );

    const applied = await migrate(pool, { log: () => {} });
    assert.ok(applied >= 1);
    const names = (await pool.query('SELECT name FROM schema_migrations ORDER BY name')).rows.map((r) => r.name);
    assert.ok(names.includes('002_email_tokens.sql'));

    const user = await pool.query('SELECT email_verified_at FROM users WHERE id = $1', [rows[0].id]);
    assert.equal(user.rows[0].email_verified_at, null, 'existing users start unverified');

    await pool.query(
      `INSERT INTO auth_tokens (user_id, purpose, code_hash, expires_at) VALUES ($1, 'email_verify', $2, now())`,
      [rows[0].id, Buffer.alloc(32)],
    );
    await assert.rejects(
      pool.query(`INSERT INTO auth_tokens (user_id, purpose, code_hash, expires_at) VALUES ($1, 'email_verify', $2, now())`, [
        rows[0].id,
        Buffer.alloc(32),
      ]),
      /duplicate key/,
      'one live code per (user, purpose)',
    );
    await assert.rejects(
      pool.query(`INSERT INTO auth_tokens (user_id, purpose, code_hash, expires_at) VALUES ($1, 'other', $2, now())`, [
        rows[0].id,
        Buffer.alloc(32),
      ]),
      /check constraint/,
    );
    await pool.query('DELETE FROM users WHERE id = $1', [rows[0].id]);
    assert.equal((await pool.query('SELECT count(*)::int AS n FROM auth_tokens')).rows[0].n, 0, 'cascade on user delete');

    assert.equal(await migrate(pool, { log: () => {} }), 0, 'idempotent');
  });
});

function captureLog() {
  const lines = [];
  const at = (level) => (msg, fields) => lines.push({ level, msg, ...fields });
  return { lines, log: { debug: at('debug'), info: at('info'), warn: at('warn'), error: at('error') } };
}

describe('email config', () => {
  test('EMAIL_DAILY_CAP below 2 is clamped to 2 with a warning (0 does not become 90)', () => {
    for (const raw of ['0', '1', '-4']) {
      const { log, lines } = captureLog();
      assert.equal(loadConfig({ EMAIL_DAILY_CAP: raw }, { log }).email.dailyCap, 2, raw);
      assert.equal(lines.filter((l) => l.level === 'warn').length, 1, raw);
      assert.match(lines[0].msg, /EMAIL_DAILY_CAP/);
    }
    for (const [raw, cap] of [
      ['2', 2],
      ['40', 40],
      [undefined, 90],
      ['', 90],
      ['lots', 90],
    ]) {
      const { log, lines } = captureLog();
      assert.equal(loadConfig({ EMAIL_DAILY_CAP: raw }, { log }).email.dailyCap, cap, String(raw));
      assert.equal(lines.length, 0, String(raw));
    }
  });

  test('CODE_HMAC_KEY is read from the environment (unset = empty)', () => {
    assert.equal(loadConfig({}).codeHmacKey, '');
    assert.equal(loadConfig({ CODE_HMAC_KEY: ' abc123 ' }).codeHmacKey, 'abc123');
  });

  test('loadConfig reads EMAIL_* with safe defaults', () => {
    assert.deepEqual(loadConfig({}).email, { provider: 'log', from: '', apiKey: '', dailyCap: 90, production: false });
    assert.deepEqual(
      loadConfig({
        EMAIL_PROVIDER: 'Resend',
        EMAIL_FROM: 'Securely Hello <no-reply@thenn.in>',
        EMAIL_API_KEY: 'k',
        EMAIL_DAILY_CAP: '250',
        NODE_ENV: 'production',
      }).email,
      { provider: 'resend', from: 'Securely Hello <no-reply@thenn.in>', apiKey: 'k', dailyCap: 250, production: true },
    );
  });
});
