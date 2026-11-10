import assert from 'node:assert/strict';
import { describe, test } from 'node:test';

import { poolConfigFromUrl } from '../src/db.js';

describe('DATABASE_URL handling', () => {
  test('Neon URLs use verified TLS and drop libpq-only params', () => {
    const cfg = poolConfigFromUrl(
      'postgresql://app:secret@ep-cool-name-123456.us-east-2.aws.neon.tech/neondb?sslmode=require&channel_binding=require',
    );
    assert.deepEqual(cfg.ssl, { rejectUnauthorized: true });
    assert.equal(cfg.connectionString.includes('sslmode'), false);
    assert.equal(cfg.connectionString.includes('channel_binding'), false);
    assert.ok(cfg.connectionString.includes('neondb'));
  });

  test('Neon host without sslmode still uses TLS', () => {
    assert.deepEqual(poolConfigFromUrl('postgresql://a:b@ep-x.eu-central-1.aws.neon.tech/db').ssl, {
      rejectUnauthorized: true,
    });
  });

  test('local URLs without sslmode, or sslmode=disable, connect in plaintext', () => {
    assert.equal(poolConfigFromUrl('postgresql://sh:pw@127.0.0.1:55432/securelyhello').ssl, false);
    assert.equal(poolConfigFromUrl('postgresql://sh:pw@db.example.com/x?sslmode=disable').ssl, false);
    assert.deepEqual(poolConfigFromUrl('postgresql://sh:pw@db.example.com/x?sslmode=verify-full').ssl, {
      rejectUnauthorized: true,
    });
  });

  test('a missing DATABASE_URL is a clear error', () => {
    assert.throws(() => poolConfigFromUrl(undefined), /DATABASE_URL is not set/);
  });
});
