// Hardening of the e-mail code flows and session revocation: quota ordering,
// per-e-mail/IP daily limits, the 60 s reissue guard, Unicode e-mail keys,
// the "sessions revoked at" marker, HMAC code hashes.
import assert from 'node:assert/strict';
import { createHash, createHmac } from 'node:crypto';
import { after, before, beforeEach, describe, test } from 'node:test';

import { DEFAULT_LIMITS } from '../src/ratelimit.js';
import { hashPassword, hashToken, resolveCodeKey } from '../src/security.js';
import * as v from '../src/validate.js';
import { api, fakeKey, signup, startServer } from './helpers.js';

const DAY = 24 * 60 * 60_000;
const CODE_KEY = 'test-code-hmac-key-0123456789abcdef0123456789abcdef';

let srv;
before(async () => {
  srv = await startServer({ env: { CODE_HMAC_KEY: CODE_KEY } });
});
after(() => srv.close());
beforeEach(async () => {
  await srv.drain();
  srv.outbox.length = 0;
});

/** Temporarily replaces rate limits (fresh counters) for one test. */
async function withLimits(defs, fn) {
  const clear = async () => {
    for (const name of Object.keys(defs)) {
      const keys = await srv.redis.keys(`sh:rl:${name}:*`);
      if (keys.length) await srv.redis.del(...keys);
    }
  };
  const prev = {};
  await clear();
  for (const [name, def] of Object.entries(defs)) {
    prev[name] = srv.app.limits.defs[name];
    srv.app.limits.defs[name] = def;
  }
  try {
    return await fn();
  } finally {
    await srv.drain();
    Object.assign(srv.app.limits.defs, prev);
    // Sliding (ZSET) and fixed (string) counters can't share a key.
    await clear();
  }
}

const codeOf = (mail) => /\b(\d{6})\b/.exec(mail.text)[1];
const ageCodes = (userId) =>
  srv.pool.query(`UPDATE auth_tokens SET created_at = now() - interval '61 seconds' WHERE user_id = $1`, [userId]);

async function requestReset(email, headers) {
  const res = await api(srv.base, 'POST', '/api/auth/request-password-reset', { body: { email }, headers });
  await srv.drain();
  return res;
}
async function requestVerification(token) {
  const res = await api(srv.base, 'POST', '/api/auth/request-verification', { token });
  await srv.drain();
  return res;
}
const reset = (email, code, new_password = 'a brand new passphrase') =>
  api(srv.base, 'POST', '/api/auth/reset-password', { body: { email, code, new_password } });
const signin = (email, password) => api(srv.base, 'POST', '/api/auth/signin', { body: { email, password } });

describe('request-verification quota ordering', () => {
  test('a 503 over the global cap does not spend the per-user token', async () => {
    const a = await signup(srv.base, 'qorder');
    await withLimits({ emailVerifyUser: { capacity: 1, perMs: 60 * 60_000 } }, async () => {
      for (const name of ['emailDaily', 'emailVerifyDaily']) {
        await withLimits({ [name]: { capacity: 0, perMs: DAY, sliding: true } }, async () => {
          assert.equal((await requestVerification(a.token)).status, 503, name);
          assert.equal((await requestVerification(a.token)).status, 503, name);
        });
      }
      const ok = await requestVerification(a.token);
      assert.equal(ok.status, 200, 'the per-user budget is intact');
      assert.equal(srv.outbox.length, 1);
    });
  });

  test('a per-user 429 does not spend the global quota', async () => {
    const [a, b, c] = [await signup(srv.base, 'qa'), await signup(srv.base, 'qb'), await signup(srv.base, 'qc')];
    await withLimits(
      {
        emailVerifyUser: { capacity: 1, perMs: 60 * 60_000 },
        emailVerifyDaily: { capacity: 2, perMs: DAY, sliding: true },
      },
      async () => {
        assert.equal((await requestVerification(a.token)).status, 200);
        await ageCodes(a.id);
        assert.equal((await requestVerification(a.token)).status, 429);
        assert.equal((await requestVerification(a.token)).status, 429);
        assert.equal((await requestVerification(b.token)).status, 200, 'the 429s left global room');
        assert.equal((await requestVerification(c.token)).status, 503);
      },
    );
  });
});

describe('per-e-mail and per-IP daily reset limits', () => {
  test('defaults: 5 per e-mail per day, 20 per IP per day', () => {
    assert.deepEqual(DEFAULT_LIMITS.pwResetEmailDaily, { capacity: 5, perMs: DAY });
    assert.deepEqual(DEFAULT_LIMITS.pwResetIpDaily, { capacity: 20, perMs: DAY });
  });

  test('the 6th request for one e-mail in a day is 429, identical for known and unknown', async () => {
    const a = await signup(srv.base, 'daily');
    await withLimits({ pwResetEmailDaily: DEFAULT_LIMITS.pwResetEmailDaily }, async () => {
      const seen = {};
      for (const email of [a.email, 'ghost-daily@example.test']) {
        for (let i = 0; i < 5; i++) {
          await ageCodes(a.id);
          assert.equal((await requestReset(email)).status, 200);
        }
        await ageCodes(a.id);
        seen[email] = await requestReset(email.toUpperCase());
      }
      assert.equal(seen[a.email].status, 429);
      assert.deepEqual(seen[a.email], seen['ghost-daily@example.test']);
      assert.equal(srv.outbox.length, 5);
    });
  });

  test('the 21st request from one IP in a day is 429', async () => {
    await withLimits({ pwResetIpDaily: DEFAULT_LIMITS.pwResetIpDaily }, async () => {
      for (let i = 0; i < 20; i++) assert.equal((await requestReset(`ipd${i}@example.test`)).status, 200);
      const res = await requestReset('ipd-last@example.test');
      assert.equal(res.status, 429);
      assert.equal(res.body.error, 'rate_limited');
    });
  });
});

describe('60 s reissue guard', () => {
  test('a second reset request within 60 s: same 200, no mail, the first code still works', async () => {
    const a = await signup(srv.base, 'guard');
    const first = await requestReset(a.email);
    const second = await requestReset(a.email);
    assert.deepEqual(second, first);
    assert.equal(srv.outbox.length, 1);
    const code = codeOf(srv.outbox[0]);
    await ageCodes(a.id);
    await requestReset(a.email);
    assert.equal(srv.outbox.length, 2, 'after 60 s a new code is sent');
    const newest = codeOf(srv.outbox[1]);
    if (newest !== code) assert.equal((await reset(a.email, code)).status, 400);
    assert.equal((await reset(a.email, newest)).status, 204);
  });

  test('the guard does not apply to an expired code', async () => {
    const a = await signup(srv.base, 'guardexp');
    await requestReset(a.email);
    await srv.pool.query(`UPDATE auth_tokens SET expires_at = now() - interval '1 second' WHERE user_id = $1`, [a.id]);
    await requestReset(a.email);
    assert.equal(srv.outbox.length, 2);
  });

  test('a guarded reset request spends no daily e-mail quota', async () => {
    const a = await signup(srv.base, 'guardq');
    await withLimits({ emailDaily: { capacity: 1, perMs: DAY, sliding: true } }, async () => {
      await requestReset(a.email);
      await requestReset(a.email);
      await requestReset(a.email);
      const n = await srv.redis.zcard('sh:rl:emailDaily:global');
      assert.equal(n, 1);
    });
  });

  test('a second verification request within 60 s: same 200, no mail, no quota spent', async () => {
    const a = await signup(srv.base, 'vguard');
    await withLimits({ emailVerifyUser: { capacity: 1, perMs: 60 * 60_000 } }, async () => {
      const first = await requestVerification(a.token);
      const second = await requestVerification(a.token);
      assert.equal(first.status, 200);
      assert.deepEqual(second, first);
      assert.equal(srv.outbox.length, 1);
      const code = codeOf(srv.outbox[0]);
      const ok = await api(srv.base, 'POST', '/api/auth/verify-email', { token: a.token, body: { code } });
      assert.equal(ok.status, 200);
    });
  });
});

describe('Unicode e-mails and rate-limit keys', () => {
  test('strict validation (signup, reset) rejects markup, separators, quotes, spaces and non-ASCII', () => {
    for (const ok of ['a@b.co', 'First.Last+tag@sub.example.co', 'x_y-z@xn--bcher-kva.example']) {
      assert.equal(v.email(ok, { strict: true }), ok);
    }
    for (const badEmail of [
      '<a@b.co>',
      'a<b@c.co',
      'a>b@c.co',
      'a,b@c.co',
      '"a"@b.co',
      "o'b@c.co",
      'a b@c.co',
      'vİctim@example.test',
      'ü@b.co',
      'a@bü.co',
      'a@b.co​',
      'a@b',
    ]) {
      assert.throws(
        () => v.email(badEmail, { strict: true }),
        (err) => err.status === 400 && err.code === 'invalid_email',
        badEmail,
      );
    }
  });

  test('lenient validation (sign-in) still accepts any stored address shape', () => {
    for (const legacy of ['vİctim@example.test', "o'b@c.co", 'ü@b.co']) assert.equal(v.email(legacy), legacy);
  });

  test("'vİctim' is rejected by signup, request-password-reset and reset-password", async () => {
    const victim = await signup(srv.base, 'victim');
    const variant = victim.email.replace('vi', 'vİ');
    assert.notEqual(variant, victim.email);
    // Postgres lower() folds İ to i, so this variant would match the account.
    const { rows } = await srv.pool.query('SELECT id FROM users WHERE lower(email) = lower($1)', [variant]);
    assert.equal(rows[0]?.id, victim.id);

    const up = await api(srv.base, 'POST', '/api/auth/signup', {
      body: {
        email: variant,
        password: 'long enough password',
        username: `x${victim.username}`.slice(0, 30),
        signing_public_key: fakeKey(),
        encryption_public_key: fakeKey(),
      },
    });
    assert.equal(up.status, 400);
    assert.equal(up.body.error, 'invalid_email');

    const rq = await requestReset(variant);
    assert.equal(rq.status, 400);
    assert.equal(rq.body.error, 'invalid_email');
    assert.equal(srv.outbox.length, 0);

    const rs = await reset(variant, '123456');
    assert.equal(rs.status, 400);
    assert.equal(rs.body.error, 'invalid_email');
  });

  test("sign-in with 'vİctim' variants shares the victim's per-account budget", async () => {
    const victim = await signup(srv.base, 'victim2');
    const variants = [victim.email.replace('vi', 'vİ'), victim.email.replace('vi', 'Vİ'), victim.email.toUpperCase().replace('VI', 'Vİ')];
    await withLimits({ authAccount: { capacity: 3, perMs: 15 * 60_000 } }, async () => {
      for (const email of variants) assert.equal((await signin(email, 'wrong password')).status, 401);
      const res = await signin(victim.email, victim.password);
      assert.equal(res.status, 429, 'variants did not get fresh budgets');
    });
  });

  test('sign-in still works for a legacy non-ASCII address stored before validation tightened', async () => {
    const email = `ünï_${Date.now()}@example.test`;
    await srv.pool.query(
      `INSERT INTO users (email, username, display_name, password_hash, signing_public_key, encryption_public_key)
       VALUES ($1, $2, 'Legacy', $3, $4, $5)`,
      [email, `legacy_${Date.now() % 1e9}`, await hashPassword('legacy password'), fakeKey(), fakeKey()],
    );
    assert.equal((await signin(email, 'legacy password')).status, 200);
    assert.equal((await signin(email.toUpperCase(), 'legacy password')).status, 200);
  });
});

describe('sessions revoked-at marker', () => {
  const hex = (token) => hashToken(token).toString('hex');

  test('a session re-cached by a lookup that started before a reset is rejected', async () => {
    const a = await signup(srv.base, 'race');
    assert.equal((await api(srv.base, 'GET', '/api/me', { token: a.token })).status, 200);
    // A request that read the session row before the reset committed...
    const lookupStartedAt = Date.now() - 5;
    await requestReset(a.email);
    assert.equal((await reset(a.email, codeOf(srv.outbox.at(-1)))).status, 204);
    // ...and only then wrote the cache entry.
    await srv.store.cacheSession(hex(a.token), a.id, 300, lookupStartedAt);
    assert.equal((await api(srv.base, 'GET', '/api/me', { token: a.token })).status, 401);
  });

  for (const [name, revoke] of [
    [
      'reset-password',
      async (a) => {
        await requestReset(a.email);
        assert.equal((await reset(a.email, codeOf(srv.outbox.at(-1)))).status, 204);
      },
    ],
    [
      'change-password',
      async (a) => {
        const res = await api(srv.base, 'POST', '/api/auth/change-password', {
          token: a.token,
          body: { current_password: a.password, new_password: 'another long password' },
        });
        assert.equal(res.status, 204);
      },
    ],
    [
      'account deletion',
      async (a) => assert.equal((await api(srv.base, 'DELETE', '/api/me', { token: a.token })).status, 204),
    ],
  ]) {
    test(`${name} sets the marker and stale cached sessions are refused`, async () => {
      const a = await signup(srv.base, 'mark');
      const other = await signin(a.email, a.password);
      const before = Date.now() - 5;
      await revoke(a);
      const marker = Number(await srv.redis.get(`sh:revoked:${a.id}`));
      assert.ok(marker >= before, 'marker set');
      const ttl = await srv.redis.ttl(`sh:revoked:${a.id}`);
      assert.ok(ttl > 0, 'marker expires');
      await srv.store.cacheSession(hex(other.body.token), a.id, 300, before);
      assert.equal((await api(srv.base, 'GET', '/api/me', { token: other.body.token })).status, 401);
    });
  }

  test('a session cached after the marker is served from the cache', async () => {
    const a = await signup(srv.base, 'fresh');
    const res = await api(srv.base, 'POST', '/api/auth/change-password', {
      token: a.token,
      body: { current_password: a.password, new_password: 'another long password' },
    });
    assert.equal(res.status, 204);
    await new Promise((r) => setTimeout(r, 5));
    assert.equal((await api(srv.base, 'GET', '/api/me', { token: a.token })).status, 200, 'kept session re-cached');
    // Remove the row: only a valid cache entry can still answer.
    await srv.pool.query('DELETE FROM sessions WHERE token_hash = $1', [hashToken(a.token)]);
    assert.equal((await srv.app.services.authenticate(a.token))?.id, a.id);
  });

  test('legacy cache entries without a timestamp fall back to Postgres', async () => {
    const a = await signup(srv.base, 'legacy');
    await srv.redis.set(`sh:sess:${hex(a.token)}`, a.id, 'EX', 300);
    await srv.pool.query('DELETE FROM sessions WHERE user_id = $1', [a.id]);
    assert.equal(await srv.app.services.authenticate(a.token), null);
  });
});

describe('change-password and pending reset codes', () => {
  test('a normal password change deletes a pending password_reset code', async () => {
    const a = await signup(srv.base, 'chpending');
    await requestReset(a.email);
    const code = codeOf(srv.outbox.at(-1));
    const res = await api(srv.base, 'POST', '/api/auth/change-password', {
      token: a.token,
      body: { current_password: a.password, new_password: 'another long password' },
    });
    assert.equal(res.status, 204);
    const { rows } = await srv.pool.query(
      `SELECT count(*)::int AS n FROM auth_tokens WHERE user_id = $1 AND purpose = 'password_reset'`,
      [a.id],
    );
    assert.equal(rows[0].n, 0);
    const late = await reset(a.email, code);
    assert.equal(late.status, 400);
    assert.equal(late.body.error, 'invalid_code');
    assert.equal((await signin(a.email, 'another long password')).status, 200);
  });
});

describe('HMAC code hashes', () => {
  test('stored hashes are HMAC-SHA256 under CODE_HMAC_KEY, not plain SHA-256', async () => {
    const a = await signup(srv.base, 'hmac');
    await requestReset(a.email);
    const code = codeOf(srv.outbox.at(-1));
    const { rows } = await srv.pool.query(
      `SELECT code_hash FROM auth_tokens WHERE user_id = $1 AND purpose = 'password_reset'`,
      [a.id],
    );
    const msg = `password_reset:${a.id}:${code}`;
    assert.deepEqual(rows[0].code_hash, createHmac('sha256', CODE_KEY).update(msg).digest());
    assert.notDeepEqual(rows[0].code_hash, createHash('sha256').update(msg).digest());
  });

  test('resolveCodeKey: configured key is used; unset derives a random per-process key and warns in production', () => {
    const lines = [];
    const log = { warn: (msg) => lines.push(msg), info: () => {} };
    assert.deepEqual(resolveCodeKey('abc', { production: true, log }), Buffer.from('abc'));
    assert.equal(lines.length, 0);
    const k1 = resolveCodeKey('', { production: false, log });
    assert.equal(k1.length, 32);
    assert.equal(lines.length, 0, 'no warning in development');
    const k2 = resolveCodeKey(undefined, { production: true, log });
    assert.equal(k2.length, 32);
    assert.notDeepEqual(k1, k2);
    assert.equal(lines.length, 1);
    assert.match(lines[0], /CODE_HMAC_KEY/);
  });
});
