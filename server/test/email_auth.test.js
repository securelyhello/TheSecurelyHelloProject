import assert from 'node:assert/strict';
import { after, before, beforeEach, describe, test } from 'node:test';

import { DEFAULT_LIMITS, emailLimits } from '../src/ratelimit.js';
import { hashEmailCode, newEmailCode } from '../src/security.js';
import { code as validCode } from '../src/validate.js';
import { api, connectWs, signup, startServer } from './helpers.js';

const HOUR = 60 * 60_000;
const NEW_PW = 'a brand new passphrase';

let srv;
before(async () => {
  srv = await startServer();
});
after(() => srv.close());
beforeEach(async () => {
  await srv.drain();
  srv.outbox.length = 0;
});

/** Temporarily tightens a rate limit (fresh counters) for one test. */
async function withLimit(name, def, fn) {
  const keys = await srv.redis.keys(`sh:rl:${name}:*`);
  if (keys.length) await srv.redis.del(...keys);
  const prev = srv.app.limits.defs[name];
  srv.app.limits.defs[name] = def;
  try {
    return await fn();
  } finally {
    srv.app.limits.defs[name] = prev;
  }
}

/** Backdates a user's codes past the 60 s reissue guard. */
const ageCodes = (userId) =>
  srv.pool.query(`UPDATE auth_tokens SET created_at = now() - interval '2 minutes' WHERE user_id = $1`, [userId]);

const codeOf = (mail) => /\b(\d{6})\b/.exec(mail.text)[1];
const wrong = (code) => String((Number(code) + 1) % 1_000_000).padStart(6, '0');

async function requestReset(email) {
  const res = await api(srv.base, 'POST', '/api/auth/request-password-reset', { body: { email } });
  await srv.drain();
  return res;
}

async function resetCode(user) {
  const res = await requestReset(user.email);
  assert.equal(res.status, 200);
  const mails = srv.outbox.filter((m) => m.to === user.email);
  return codeOf(mails.at(-1));
}

const reset = (email, code, new_password = NEW_PW) =>
  api(srv.base, 'POST', '/api/auth/reset-password', { body: { email, code, new_password } });

const signin = (email, password) => api(srv.base, 'POST', '/api/auth/signin', { body: { email, password } });

describe('email codes', () => {
  test('newEmailCode() is six zero-padded digits', () => {
    const seen = new Set();
    for (let i = 0; i < 2000; i++) {
      const c = newEmailCode();
      assert.match(c, /^\d{6}$/);
      seen.add(c);
    }
    assert.ok(seen.size > 1900, 'codes are random');
  });

  test('hashEmailCode() binds key, purpose, user and code', () => {
    const u1 = '00000000-0000-4000-8000-000000000001';
    const u2 = '00000000-0000-4000-8000-000000000002';
    const key = Buffer.from('k'.repeat(32));
    const h = hashEmailCode(key, 'password_reset', u1, '012345');
    assert.equal(h.length, 32);
    assert.deepEqual(h, hashEmailCode(key, 'password_reset', u1, '012345'));
    assert.notDeepEqual(h, hashEmailCode(key, 'email_verify', u1, '012345'));
    assert.notDeepEqual(h, hashEmailCode(key, 'password_reset', u2, '012345'));
    assert.notDeepEqual(h, hashEmailCode(key, 'password_reset', u1, '012346'));
    assert.notDeepEqual(h, hashEmailCode(Buffer.from('x'.repeat(32)), 'password_reset', u1, '012345'));
  });

  test('validate.code() accepts exactly six digits', () => {
    assert.equal(validCode('000123'), '000123');
    assert.equal(validCode(' 000123 '), '000123');
    for (const bad of ['12345', '1234567', '12a456', 123456, null, undefined, '١٢٣٤٥٦']) {
      assert.throws(() => validCode(bad), (err) => err.status === 400 && err.code === 'invalid_code');
    }
  });
});

describe('request-password-reset', () => {
  test('identical 200 {ok:true} for known and unknown e-mails; only the known one gets mail', async () => {
    const a = await signup(srv.base, 'rq');
    const known = await requestReset(a.email);
    const unknown = await requestReset('nobody-here@example.test');
    assert.equal(known.status, 200);
    assert.deepEqual(known, unknown);
    assert.deepEqual(known.body, { ok: true });
    assert.equal(srv.outbox.length, 1);
    assert.equal(srv.outbox[0].to, a.email);
    assert.equal(srv.outbox[0].template, 'password_reset');
    assert.equal(srv.outbox[0].userId, a.id);
    assert.match(codeOf(srv.outbox[0]), /^\d{6}$/);
  });

  test('e-mail matching is case-insensitive and mail goes to the stored address', async () => {
    const a = await signup(srv.base, 'rqcase');
    await requestReset(a.email.toUpperCase());
    assert.equal(srv.outbox.length, 1);
    assert.equal(srv.outbox[0].to, a.email);
  });

  test('invalid e-mail is a 400 invalid_email', async () => {
    const res = await requestReset('not-an-email');
    assert.equal(res.status, 400);
    assert.equal(res.body.error, 'invalid_email');
  });

  test('only a hash of the code is stored, with a ~15 minute expiry', async () => {
    const a = await signup(srv.base, 'rqhash');
    const code = await resetCode(a);
    const { rows } = await srv.pool.query(
      `SELECT code_hash, attempts, extract(epoch FROM expires_at - now()) AS ttl
         FROM auth_tokens WHERE user_id = $1 AND purpose = 'password_reset'`,
      [a.id],
    );
    assert.equal(rows.length, 1);
    assert.equal(rows[0].attempts, 0);
    assert.ok(Buffer.isBuffer(rows[0].code_hash) && rows[0].code_hash.length === 32);
    assert.equal(rows[0].code_hash.toString('utf8').includes(code), false);
    assert.equal(rows[0].code_hash.toString('hex').includes(code), false);
    assert.ok(Number(rows[0].ttl) > 14 * 60 && Number(rows[0].ttl) <= 15 * 60);
  });

  test('a second request replaces the code: the old one no longer works', async () => {
    const a = await signup(srv.base, 'rqtwice');
    const first = await resetCode(a);
    await ageCodes(a.id);
    const second = await resetCode(a);
    const { rows } = await srv.pool.query('SELECT count(*)::int AS n FROM auth_tokens WHERE user_id = $1', [a.id]);
    assert.equal(rows[0].n, 1);
    if (first !== second) {
      const old = await reset(a.email, first);
      assert.equal(old.status, 400);
      assert.equal(old.body.error, 'invalid_code');
    }
    assert.equal((await reset(a.email, second)).status, 204);
  });

  test('per-e-mail limit: 429s are identical for known and unknown accounts', async () => {
    const a = await signup(srv.base, 'rqlimit');
    await withLimit('pwResetEmail', { capacity: 3, perMs: HOUR }, async () => {
      const seen = {};
      for (const email of [a.email, 'ghost-limit@example.test']) {
        for (let i = 0; i < 3; i++) {
          await ageCodes(a.id);
          assert.equal((await requestReset(email)).status, 200);
        }
        seen[email] = await requestReset(email.toUpperCase());
      }
      assert.equal(seen[a.email].status, 429);
      assert.equal(seen[a.email].body.error, 'rate_limited');
      assert.deepEqual(seen[a.email], seen['ghost-limit@example.test']);
      assert.equal(srv.outbox.length, 3);
    });
  });

  test('per-IP limit: 429s are identical for known and unknown accounts', async () => {
    const a = await signup(srv.base, 'rqip');
    await withLimit('pwResetIp', { capacity: 5, perMs: HOUR }, async () => {
      for (let i = 0; i < 5; i++) assert.equal((await requestReset(`ip${i}@example.test`)).status, 200);
      const k = await requestReset(a.email);
      const u = await requestReset('ghost-ip@example.test');
      assert.equal(k.status, 429);
      assert.deepEqual(k, u);
      assert.equal(srv.outbox.length, 0);
    });
  });

  test('over the daily e-mail cap: still 200, but no mail is sent', async () => {
    const a = await signup(srv.base, 'rqcap');
    await withLimit('emailDaily', { capacity: 0, perMs: 24 * HOUR }, async () => {
      const res = await requestReset(a.email);
      assert.equal(res.status, 200);
      assert.deepEqual(res.body, { ok: true });
      assert.equal(srv.outbox.length, 0);
    });
  });
});

describe('reset-password', () => {
  test('happy path: new password works, old fails, every session and socket is revoked', async () => {
    const a = await signup(srv.base, 'rsok');
    const second = await signin(a.email, a.password);
    assert.equal(second.status, 200);
    // Warm the Redis session cache for both tokens.
    assert.equal((await api(srv.base, 'GET', '/api/me', { token: a.token })).status, 200);
    assert.equal((await api(srv.base, 'GET', '/api/me', { token: second.body.token })).status, 200);
    const ws = await connectWs(srv.wsUrl, a.token);
    const closed = new Promise((resolve) => ws.ws.once('close', (code) => resolve(code)));

    const code = await resetCode(a);
    const res = await reset(a.email.toUpperCase(), code);
    assert.equal(res.status, 204);
    assert.equal(res.body, undefined, 'no token is returned');

    assert.equal(await closed, 4003);
    assert.equal((await api(srv.base, 'GET', '/api/me', { token: a.token })).status, 401);
    assert.equal((await api(srv.base, 'GET', '/api/me', { token: second.body.token })).status, 401);
    assert.equal((await signin(a.email, a.password)).status, 401);
    const fresh = await signin(a.email, NEW_PW);
    assert.equal(fresh.status, 200);
    assert.equal(fresh.body.user.email_verified, true, 'a successful reset proves the mailbox');
    const left = await srv.pool.query('SELECT count(*)::int AS n FROM auth_tokens WHERE user_id = $1', [a.id]);
    assert.equal(left.rows[0].n, 0);
  });

  test('a code is single use', async () => {
    const a = await signup(srv.base, 'rsonce');
    const code = await resetCode(a);
    assert.equal((await reset(a.email, code)).status, 204);
    const again = await reset(a.email, code, 'yet another passphrase');
    assert.equal(again.status, 400);
    assert.equal(again.body.error, 'invalid_code');
    assert.equal((await signin(a.email, NEW_PW)).status, 200);
  });

  test('an expired code is rejected', async () => {
    const a = await signup(srv.base, 'rsexp');
    const code = await resetCode(a);
    await srv.pool.query(`UPDATE auth_tokens SET expires_at = now() - interval '1 second' WHERE user_id = $1`, [a.id]);
    const res = await reset(a.email, code);
    assert.equal(res.status, 400);
    assert.equal(res.body.error, 'invalid_code');
    assert.equal((await signin(a.email, a.password)).status, 200);
  });

  test('wrong attempts count; after the 5th wrong one the code is dead', async () => {
    const a = await signup(srv.base, 'rsbrute');
    const code = await resetCode(a);
    for (let i = 0; i < 5; i++) {
      const res = await reset(a.email, wrong(code));
      assert.equal(res.status, 400);
      assert.equal(res.body.error, 'invalid_code');
    }
    const res = await reset(a.email, code);
    assert.equal(res.status, 400, 'the 6th attempt fails even with the right code');
    assert.equal(res.body.error, 'invalid_code');
    assert.equal((await signin(a.email, a.password)).status, 200);
  });

  test('wrong attempts below the limit are committed but the right code still works', async () => {
    const a = await signup(srv.base, 'rsfew');
    const code = await resetCode(a);
    for (let i = 0; i < 4; i++) assert.equal((await reset(a.email, wrong(code))).status, 400);
    const { rows } = await srv.pool.query('SELECT attempts FROM auth_tokens WHERE user_id = $1', [a.id]);
    assert.equal(rows[0].attempts, 4);
    assert.equal((await reset(a.email, code)).status, 204);
  });

  test('weak_password does not consume the code', async () => {
    const a = await signup(srv.base, 'rsweak');
    const code = await resetCode(a);
    const weak = await reset(a.email, code, 'short');
    assert.equal(weak.status, 400);
    assert.equal(weak.body.error, 'weak_password');
    const { rows } = await srv.pool.query('SELECT attempts FROM auth_tokens WHERE user_id = $1', [a.id]);
    assert.equal(rows[0].attempts, 0);
    assert.equal((await reset(a.email, code)).status, 204);
  });

  test('unknown e-mail, malformed code and no code all give the same invalid_code', async () => {
    const a = await signup(srv.base, 'rsunk');
    await resetCode(a);
    const unknown = await reset('nobody-at-all@example.test', '123456');
    assert.equal(unknown.status, 400);
    assert.equal(unknown.body.error, 'invalid_code');
    for (const code of ['12345', '1234567', 'abcdef', 123456, null]) {
      const res = await reset(a.email, code);
      assert.equal(res.status, 400);
      assert.deepEqual(res.body, unknown.body);
    }
  });

  test('works for an unverified account and marks it verified', async () => {
    const a = await signup(srv.base, 'rsunv');
    assert.equal(a.user.email_verified, false);
    assert.equal((await reset(a.email, await resetCode(a))).status, 204);
    const { rows } = await srv.pool.query('SELECT email_verified_at FROM users WHERE id = $1', [a.id]);
    assert.ok(rows[0].email_verified_at instanceof Date);
  });

  test('code attempts are rate limited per e-mail', async () => {
    const a = await signup(srv.base, 'rsrate');
    const code = await resetCode(a);
    await withLimit('codeAttempt', { capacity: 2, perMs: 15 * 60_000 }, async () => {
      assert.equal((await reset(a.email, wrong(code))).status, 400);
      assert.equal((await reset(a.email, wrong(code))).status, 400);
      const res = await reset(a.email, code);
      assert.equal(res.status, 429);
    });
  });

  test('the per-IP auth limit applies', async () => {
    await withLimit('authIp', { capacity: 0, perMs: 60_000 }, async () => {
      const res = await reset('x@example.test', '123456');
      assert.equal(res.status, 429);
    });
  });
});

describe('email verification', () => {
  const requestVerification = async (token) => {
    const res = await api(srv.base, 'POST', '/api/auth/request-verification', { token });
    await srv.drain();
    return res;
  };
  const verify = (token, code) => api(srv.base, 'POST', '/api/auth/verify-email', { token, body: { code } });
  const verifyCode = async (user) => {
    assert.equal((await requestVerification(user.token)).status, 200);
    return codeOf(srv.outbox.filter((m) => m.to === user.email).at(-1));
  };

  test('signup does not send mail and reports email_verified:false; public profiles omit it', async () => {
    const a = await signup(srv.base, 'vnew');
    const b = await signup(srv.base, 'vother');
    await srv.drain();
    assert.equal(srv.outbox.length, 0);
    assert.equal(a.user.email_verified, false);
    const me = await api(srv.base, 'GET', '/api/me', { token: a.token });
    assert.equal(me.body.email_verified, false);
    assert.equal('email_verified_at' in me.body, false);
    const pub = await api(srv.base, 'GET', `/api/users/${a.id}`, { token: b.token });
    assert.equal(pub.status, 200);
    assert.equal('email_verified' in pub.body, false);
    assert.equal('email_verified_at' in pub.body, false);
  });

  test('both endpoints require a session', async () => {
    assert.equal((await api(srv.base, 'POST', '/api/auth/request-verification')).status, 401);
    assert.equal((await api(srv.base, 'POST', '/api/auth/verify-email', { body: { code: '123456' } })).status, 401);
  });

  test('mails the account address and the code flips email_verified', async () => {
    const a = await signup(srv.base, 'vok');
    const res = await requestVerification(a.token);
    assert.equal(res.status, 200);
    assert.deepEqual(res.body, { ok: true });
    assert.equal(srv.outbox.length, 1);
    assert.equal(srv.outbox[0].to, a.email);
    assert.equal(srv.outbox[0].template, 'email_verify');
    const ttl = await srv.pool.query(
      `SELECT extract(epoch FROM expires_at - now()) AS ttl FROM auth_tokens WHERE user_id = $1 AND purpose = 'email_verify'`,
      [a.id],
    );
    assert.ok(Number(ttl.rows[0].ttl) > 29 * 60 && Number(ttl.rows[0].ttl) <= 30 * 60);

    const ok = await verify(a.token, codeOf(srv.outbox[0]));
    assert.equal(ok.status, 200);
    assert.equal(ok.body.email_verified, true);
    assert.equal(ok.body.user_id, a.id);
    assert.equal(ok.body.email, a.email);
    assert.equal((await api(srv.base, 'GET', '/api/me', { token: a.token })).body.email_verified, true);
    assert.equal((await signin(a.email, a.password)).body.user.email_verified, true);

    const again = await requestVerification(a.token);
    assert.equal(again.status, 409);
    assert.equal(again.body.error, 'already_verified');
  });

  test('wrong, expired and reused codes fail', async () => {
    const a = await signup(srv.base, 'vbad');
    let code = await verifyCode(a);
    const w = await verify(a.token, wrong(code));
    assert.equal(w.status, 400);
    assert.equal(w.body.error, 'invalid_code');
    assert.equal((await verify(a.token, 'nope')).body.error, 'invalid_code');

    await srv.pool.query(`UPDATE auth_tokens SET expires_at = now() - interval '1 second' WHERE user_id = $1`, [a.id]);
    assert.equal((await verify(a.token, code)).body.error, 'invalid_code');

    code = await verifyCode(a);
    assert.equal((await verify(a.token, code)).status, 200);
    // Reuse after success: the row is gone.
    const reused = await verify(a.token, code);
    assert.equal(reused.status, 400);
    assert.equal(reused.body.error, 'invalid_code');
  });

  test('five wrong codes kill the verification code', async () => {
    const a = await signup(srv.base, 'vbrute');
    const code = await verifyCode(a);
    for (let i = 0; i < 5; i++) assert.equal((await verify(a.token, wrong(code))).status, 400);
    assert.equal((await verify(a.token, code)).status, 400);
  });

  test('codes are bound to their purpose', async () => {
    const a = await signup(srv.base, 'vcross');
    const resetC = await resetCode(a);
    await verifyCode(a);
    // Copy the reset row's hash onto the verify row: the hash binds the purpose.
    await srv.pool.query(
      `UPDATE auth_tokens SET code_hash = (SELECT code_hash FROM auth_tokens WHERE user_id = $1 AND purpose = 'password_reset')
        WHERE user_id = $1 AND purpose = 'email_verify'`,
      [a.id],
    );
    const vr = await verify(a.token, resetC);
    assert.equal(vr.status, 400);
    assert.equal(vr.body.error, 'invalid_code');
    // The reset code itself is untouched and still works for its own purpose.
    assert.equal((await reset(a.email, resetC)).status, 204);
  });

  test("another user's code does not verify you", async () => {
    const a = await signup(srv.base, 'vmine');
    const b = await signup(srv.base, 'vtheirs');
    const bCode = await verifyCode(b);
    await verifyCode(a);
    // Copy b's stored hash onto a's row: the hash binds the user id, so it fails.
    await srv.pool.query(
      `UPDATE auth_tokens SET code_hash = (SELECT code_hash FROM auth_tokens WHERE user_id = $2 AND purpose = 'email_verify')
        WHERE user_id = $1 AND purpose = 'email_verify'`,
      [a.id, b.id],
    );
    const res = await verify(a.token, bCode);
    assert.equal(res.status, 400);
    assert.equal(res.body.error, 'invalid_code');
    assert.equal((await verify(b.token, bCode)).status, 200);
  });

  test('requests are rate limited per user', async () => {
    const a = await signup(srv.base, 'vlimit');
    await withLimit('emailVerifyUser', { capacity: 3, perMs: HOUR }, async () => {
      for (let i = 0; i < 3; i++) {
        await ageCodes(a.id);
        assert.equal((await requestVerification(a.token)).status, 200);
      }
      await ageCodes(a.id);
      const res = await requestVerification(a.token);
      assert.equal(res.status, 429);
      assert.equal(res.body.error, 'rate_limited');
      assert.equal(srv.outbox.length, 3);
    });
  });

  test('verify-email attempts are rate limited per user', async () => {
    const a = await signup(srv.base, 'vattempt');
    const code = await verifyCode(a);
    await withLimit('codeAttempt', { capacity: 1, perMs: 15 * 60_000 }, async () => {
      assert.equal((await verify(a.token, wrong(code))).status, 400);
      assert.equal((await verify(a.token, code)).status, 429);
    });
  });

  test('over the verification share of the daily cap: 503 unavailable, no mail', async () => {
    const a = await signup(srv.base, 'vcap');
    await withLimit('emailVerifyDaily', { capacity: 0, perMs: 24 * HOUR }, async () => {
      const res = await requestVerification(a.token);
      assert.equal(res.status, 503);
      assert.equal(res.body.error, 'unavailable');
    });
    await withLimit('emailDaily', { capacity: 0, perMs: 24 * HOUR }, async () => {
      const res = await requestVerification(a.token);
      assert.equal(res.status, 503);
    });
    assert.equal(srv.outbox.length, 0);
  });
});

describe('housekeeping', () => {
  test('sweep() deletes expired auth codes', async () => {
    const a = await signup(srv.base, 'sweep');
    await resetCode(a);
    await srv.pool.query(`UPDATE auth_tokens SET expires_at = now() - interval '1 second' WHERE user_id = $1`, [a.id]);
    const n = await srv.app.sweep();
    assert.ok(n.authTokens >= 1);
    const { rows } = await srv.pool.query('SELECT count(*)::int AS n FROM auth_tokens WHERE user_id = $1', [a.id]);
    assert.equal(rows[0].n, 0);
  });
});

describe('daily e-mail cap (shared provider quota)', () => {
  test('the global caps are sliding windows, sized from EMAIL_DAILY_CAP', () => {
    assert.equal(DEFAULT_LIMITS.emailDaily.sliding, true);
    assert.equal(DEFAULT_LIMITS.emailVerifyDaily.sliding, true);
    const caps = emailLimits(40);
    assert.deepEqual(caps.emailDaily, { capacity: 40, perMs: 24 * HOUR, sliding: true });
    assert.deepEqual(caps.emailVerifyDaily, { capacity: 26, perMs: 24 * HOUR, sliding: true });
    const def = emailLimits(90);
    assert.equal(def.emailDaily.capacity, 90);
    assert.equal(def.emailVerifyDaily.capacity, 60);
    // Below the minimum of 2 the caps are clamped (verification keeps 1 slot).
    for (const low of [0, 1, -5]) {
      assert.equal(emailLimits(low).emailDaily.capacity, 2);
      assert.equal(emailLimits(low).emailVerifyDaily.capacity, 1);
    }
  });

  test('never more than the cap in any 24 h, even across a window boundary', async () => {
    const store = srv.app.limits.store;
    const key = `boundary-${Date.now()}`;
    const t0 = 1_000_000_000_000;
    const hit = (at) => store.slidingHit('emailDaily', key, 3, 24 * HOUR, at);
    // One send early in the "day", two just before 24 h later.
    assert.equal(await hit(t0), true);
    assert.equal(await hit(t0 + 23 * HOUR), true);
    assert.equal(await hit(t0 + 23 * HOUR + 1), true);
    assert.equal(await hit(t0 + 23 * HOUR + 2), false);
    // Right after the first send ages out only one slot frees up; a fixed
    // window would have handed out a fresh 3 here (5 sends within ~1 h).
    assert.equal(await hit(t0 + 24 * HOUR + 1), true);
    assert.equal(await hit(t0 + 24 * HOUR + 2), false);
    assert.equal(await hit(t0 + 24 * HOUR + 3), false);
    // Rejected attempts are not recorded: once the 23 h sends age out, two fit.
    assert.equal(await hit(t0 + 47 * HOUR + 2), true);
    assert.equal(await hit(t0 + 47 * HOUR + 3), true);
    assert.equal(await hit(t0 + 47 * HOUR + 4), false);
    assert.equal(await store.slidingHit('emailDaily', `${key}-zero`, 0, 24 * HOUR), false);
  });

  test('password-reset mails stop at the configured cap', async () => {
    const users = [];
    for (let i = 0; i < 3; i++) users.push(await signup(srv.base, `cap${i}`));
    await withLimit('emailDaily', emailLimits(2).emailDaily, async () => {
      for (const u of users) assert.equal((await requestReset(u.email)).status, 200);
    });
    assert.equal(srv.outbox.length, 2);
  });
});
