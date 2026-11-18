// Global daily e-mail cap (EMAIL_DAILY_CAP). The Resend quota is shared with
// another product, so the server must never send more than the cap in any
// 24 h, and verification mail must not use up the headroom resets need.
import assert from 'node:assert/strict';
import { after, before, beforeEach, describe, test } from 'node:test';

import { loadConfig } from '../src/app.js';
import { DEFAULT_LIMITS, MIN_EMAIL_DAILY_CAP, emailLimits } from '../src/ratelimit.js';
import { GENEROUS_LIMITS, addDevice, api, mailCount, nextCode, signup, startServer } from './helpers.js';

const HOUR = 60 * 60_000;
const DAY = 24 * HOUR;

// Every limit generous except the two global e-mail caps, which come from
// EMAIL_DAILY_CAP like in production.
const { emailDaily: _d, emailVerifyDaily: _v, ...NON_EMAIL_LIMITS } = GENEROUS_LIMITS;

const settle = () => new Promise((r) => setTimeout(r, 150));

describe('e-mail cap configuration', () => {
  test('EMAIL_DAILY_CAP defaults to 40 and is read from the environment', () => {
    assert.equal(loadConfig({}).emailDailyCap, 40);
    assert.equal(loadConfig({ EMAIL_DAILY_CAP: '25' }).emailDailyCap, 25);
    assert.equal(loadConfig({ EMAIL_DAILY_CAP: 'lots' }).emailDailyCap, 40);
    // 0 is passed through so it can be clamped (with a warning), not silently
    // replaced by the default.
    assert.equal(loadConfig({ EMAIL_DAILY_CAP: '0' }).emailDailyCap, 0);
  });

  test('both caps are 24 h sliding windows; verification gets two thirds', () => {
    assert.equal(DEFAULT_LIMITS.emailDaily.sliding, true);
    assert.equal(DEFAULT_LIMITS.emailVerifyDaily.sliding, true);
    assert.equal(DEFAULT_LIMITS.emailDaily.capacity, 40);
    assert.equal(DEFAULT_LIMITS.emailVerifyDaily.capacity, 26);
    const caps = emailLimits(40);
    assert.deepEqual(caps.emailDaily, { capacity: 40, perMs: DAY, sliding: true });
    assert.deepEqual(caps.emailVerifyDaily, { capacity: 26, perMs: DAY, sliding: true });
    assert.equal(emailLimits(90).emailVerifyDaily.capacity, 60);
  });

  test('caps below the minimum are clamped so resets always keep a slot', () => {
    assert.equal(MIN_EMAIL_DAILY_CAP, 2);
    for (const low of [0, 1, -5, 'x', undefined]) {
      assert.equal(emailLimits(low).emailDaily.capacity, 2, `cap ${low}`);
      assert.equal(emailLimits(low).emailVerifyDaily.capacity, 1, `cap ${low}`);
    }
    assert.equal(emailLimits(7.9).emailDaily.capacity, 7);
  });
});

describe('sliding window (store)', () => {
  let srv;
  before(async () => {
    srv = await startServer();
  });
  after(() => srv.close());

  test('never more than the cap in any 24 h, even across a window boundary', async () => {
    const key = `boundary-${Date.now()}`;
    const t0 = 1_000_000_000_000;
    const hit = (at) => srv.store.slidingHit('emailDaily', key, 3, DAY, at);
    const peek = (at) => srv.store.slidingPeek('emailDaily', key, 3, DAY, at);
    assert.equal(await hit(t0), true);
    assert.equal(await hit(t0 + 23 * HOUR), true);
    assert.equal(await peek(t0 + 23 * HOUR + 1), true);
    assert.equal(await hit(t0 + 23 * HOUR + 1), true);
    assert.equal(await peek(t0 + 23 * HOUR + 2), false);
    assert.equal(await hit(t0 + 23 * HOUR + 2), false);
    // When the first send ages out exactly one slot frees up (a fixed window
    // would hand out a fresh 3 here: 5 sends within about an hour).
    assert.equal(await hit(t0 + DAY + 1), true);
    assert.equal(await hit(t0 + DAY + 2), false);
    // Rejected attempts are not recorded: once the 23 h sends age out, two fit.
    assert.equal(await hit(t0 + 47 * HOUR + 2), true);
    assert.equal(await hit(t0 + 47 * HOUR + 3), true);
    assert.equal(await hit(t0 + 47 * HOUR + 4), false);
  });

  test('peek records nothing; a zero capacity always refuses', async () => {
    const key = `peek-${Date.now()}`;
    for (let i = 0; i < 5; i++) assert.equal(await srv.store.slidingPeek('emailDaily', key, 1, DAY), true);
    assert.equal(await srv.store.slidingHit('emailDaily', key, 1, DAY), true);
    assert.equal(await srv.store.slidingPeek('emailDaily', key, 1, DAY), false);
    assert.equal(await srv.store.slidingHit('emailDaily', `${key}-z`, 0, DAY), false);
    assert.equal(await srv.store.slidingPeek('emailDaily', `${key}-z`, 0, DAY), false);
  });

  test('takeAll is all-or-nothing across caps, whichever one is full', async () => {
    const a = `all-a-${Date.now()}`;
    const b = `all-b-${Date.now()}`;
    const caps = (first, second) => [
      { bucket: 'emailDaily', key: first, capacity: 5, windowMs: DAY },
      { bucket: 'emailVerifyDaily', key: second, capacity: 1, windowMs: DAY },
    ];
    assert.equal(await srv.store.slidingTakeAll(caps(a, b)), true);
    assert.equal(await srv.redis.zcard(`sh:rl:emailDaily:${a}`), 1);
    assert.equal(await srv.redis.zcard(`sh:rl:emailVerifyDaily:${b}`), 1);
    // The second cap is full: the first one, though it has room, is untouched.
    assert.equal(await srv.store.slidingTakeAll(caps(a, b)), false);
    assert.equal(await srv.redis.zcard(`sh:rl:emailDaily:${a}`), 1);
    // Same with the full cap listed first.
    assert.equal(await srv.store.slidingTakeAll([...caps(a, b)].reverse()), false);
    assert.equal(await srv.redis.zcard(`sh:rl:emailDaily:${a}`), 1);
    assert.equal(await srv.store.slidingPeekAll(caps(a, b)), false);
    assert.equal(await srv.store.slidingPeekAll(caps(a, `${b}-free`)), true);
  });

  test('peek and take share the Redis clock: a skewed entry counts for both', async () => {
    // Another instance with a clock a minute ahead recorded a send "in the
    // future". take() counts it (it is inside the window), so peek() must too.
    const key = `skew-${Date.now()}`;
    const [secs] = await srv.redis.time();
    await srv.redis.zadd(`sh:rl:emailDaily:${key}`, Number(secs) * 1000 + 60_000, 'ahead');
    assert.equal(await srv.store.slidingPeek('emailDaily', key, 1, DAY), false);
    assert.equal(await srv.store.slidingHit('emailDaily', key, 1, DAY), false);
  });

  test('a concurrent burst of takeAll never overspends any cap', async () => {
    const key = `burst-${Date.now()}`;
    const caps = [
      { bucket: 'emailDaily', key, capacity: 100, windowMs: DAY },
      { bucket: 'emailVerifyDaily', key, capacity: 1, windowMs: DAY },
    ];
    const results = await Promise.all(Array.from({ length: 20 }, () => srv.store.slidingTakeAll(caps)));
    assert.equal(results.filter(Boolean).length, 1);
    assert.equal(await srv.redis.zcard(`sh:rl:emailDaily:${key}`), 1);
    assert.equal(await srv.redis.zcard(`sh:rl:emailVerifyDaily:${key}`), 1);
  });

  test('RateLimits.peek works for fixed-window limits too', async () => {
    const key = `fixed-${Date.now()}`;
    srv.app.limits.defs.tinyFixed = { capacity: 1, perMs: 60_000 };
    assert.equal(await srv.app.limits.peek('tinyFixed', key), true);
    assert.equal(await srv.app.limits.take('tinyFixed', key), true);
    assert.equal(await srv.app.limits.peek('tinyFixed', key), false);
    await assert.rejects(srv.app.limits.peek('nope', key), /unknown rate limit/);
  });
});

describe('EMAIL_DAILY_CAP=3 (verification share 2)', () => {
  let srv;
  before(async () => {
    srv = await startServer({ env: { EMAIL_DAILY_CAP: '3' }, baseLimits: NON_EMAIL_LIMITS });
  });
  after(() => srv.close());

  // Each test starts with an empty quota (sign-ups below spend it, so tests
  // reset again after creating their users).
  const resetQuota = () => srv.redis.del('sh:rl:emailDaily:global', 'sh:rl:emailVerifyDaily:global');
  beforeEach(resetQuota);

  const forgot = (email) => api(srv.base, 'POST', '/api/auth/password/forgot', { body: { email } });
  const sendVerification = (u) => api(srv.base, 'POST', '/api/auth/email/send-verification', { token: u.token });
  // Signs up [n] users, then empties the quota their sign-up mails used.
  // u.mails = messages they had before the test proper.
  const users = async (n, name) => {
    const out = [];
    for (let i = 0; i < n; i++) out.push(await signup(srv.base, `${name}${i}`));
    for (const u of out) u.mails = mailCount(srv, u.email);
    await resetQuota();
    return out;
  };
  const newMail = (u) => mailCount(srv, u.email) - u.mails;
  const resetCode = (u) => nextCode(srv, u.email, u.mails);

  test('the configured cap reaches the rate limits', () => {
    assert.deepEqual(srv.app.limits.defs.emailDaily, { capacity: 3, perMs: DAY, sliding: true });
    assert.deepEqual(srv.app.limits.defs.emailVerifyDaily, { capacity: 2, perMs: DAY, sliding: true });
  });

  test('the cap+1th e-mail within 24 h is not sent; reset still answers generically', async () => {
    const us = await users(4, 'rcap');
    for (const u of us.slice(0, 3)) {
      const res = await forgot(u.email);
      assert.equal(res.status, 202);
      assert.match(await resetCode(u), /^\d{6}$/);
    }
    const res = await forgot(us[3].email);
    assert.equal(res.status, 202);
    assert.deepEqual(res.body, { sent: true }, 'same answer as under the cap (no enumeration)');
    await settle();
    assert.equal(newMail(us[3]), 0);
    const codes = await srv.pool.query("SELECT 1 FROM email_codes WHERE user_id = $1 AND purpose = 'reset'", [us[3].id]);
    assert.equal(codes.rowCount, 0, 'no code is stored for a mail that was never sent');
  });

  test('verification cannot use the headroom kept for password resets', async () => {
    const us = await users(3, 'vcap');
    assert.equal((await sendVerification(us[0])).status, 202);
    assert.equal((await sendVerification(us[1])).status, 202);
    const over = await sendVerification(us[2]);
    assert.equal(over.status, 503);
    assert.equal(over.body.error, 'email_unavailable');
    assert.equal(newMail(us[0]), 1);
    assert.equal(newMail(us[2]), 0);
    // The per-user budget was not spent on a request that sent nothing.
    assert.equal(await srv.store.rateCount('emailSend', `verify:${us[2].id}`), 0);

    // The third slot is still there for a reset.
    assert.equal((await forgot(us[2].email)).status, 202);
    assert.match(await resetCode(us[2]), /^\d{6}$/);
  });

  test('parallel verification sends with one verify slot left use exactly one global slot', async () => {
    const us = await users(6, 'vburst');
    await srv.store.slidingHit('emailVerifyDaily', 'global', 2, DAY);
    const res = await Promise.all(us.map(sendVerification));
    assert.equal(res.filter((r) => r.status === 202).length, 1);
    assert.ok(res.every((r) => r.status === 202 || r.body.error === 'email_unavailable'));
    assert.equal(await srv.redis.zcard('sh:rl:emailDaily:global'), 1, 'refused sends hold no global slot');
    assert.equal(await srv.redis.zcard('sh:rl:emailVerifyDaily:global'), 2);
  });

  test('verification is refused once resets have used the whole cap', async () => {
    const us = await users(4, 'vfull');
    for (const u of us.slice(0, 3)) {
      await forgot(u.email);
      assert.match(await resetCode(u), /^\d{6}$/);
    }
    const res = await sendVerification(us[3]);
    assert.equal(res.status, 503);
    assert.equal(res.body.error, 'email_unavailable');
    assert.equal(newMail(us[3]), 0);
    assert.equal(await srv.store.rateCount('emailSend', `verify:${us[3].id}`), 0);
  });

  test('sign-up still succeeds over the cap, just without the e-mail', async () => {
    await srv.redis.del('sh:rl:emailVerifyDaily:global');
    for (let i = 0; i < 2; i++) await srv.store.slidingHit('emailVerifyDaily', 'global', 2, DAY);
    const u = await signup(srv.base, 'scap');
    assert.equal(u.user.email_verified, false);
    assert.equal(mailCount(srv, u.email), 0);
  });

  test('device recovery over the cap: 503 email_unavailable, nothing spent', async () => {
    const [a] = await users(1, 'dcap');
    const fresh = await addDevice(srv.base, a, { approve: false });
    for (let i = 0; i < 3; i++) await srv.store.slidingHit('emailDaily', 'global', 3, DAY);
    const res = await api(srv.base, 'POST', '/api/devices/current/recover', { token: fresh.token });
    assert.equal(res.status, 503);
    assert.equal(res.body.error, 'email_unavailable');
    assert.equal(newMail(a), 0);
    assert.equal(await srv.store.rateCount('emailSend', `device:${a.id}`), 0);

    // Device codes are not verification mail: they may use the whole cap.
    await resetQuota();
    for (let i = 0; i < 2; i++) await srv.store.slidingHit('emailVerifyDaily', 'global', 2, DAY);
    const ok = await api(srv.base, 'POST', '/api/devices/current/recover', { token: fresh.token });
    assert.equal(ok.status, 202);
    assert.equal(newMail(a), 1);
  });

  test('slots free up again once sends are older than 24 h', async () => {
    const us = await users(4, 'slide');
    for (const u of us.slice(0, 3)) {
      await forgot(u.email);
      assert.match(await resetCode(u), /^\d{6}$/);
    }
    await forgot(us[3].email);
    await settle();
    assert.equal(newMail(us[3]), 0);

    // Age the oldest recorded send past the window.
    const key = 'sh:rl:emailDaily:global';
    const [oldest] = await srv.redis.zrange(key, 0, 0);
    await srv.redis.zadd(key, Date.now() - DAY - 1000, oldest);

    assert.equal((await forgot(us[3].email)).status, 202);
    assert.match(await resetCode(us[3]), /^\d{6}$/);
    // ...and only that one slot.
    await forgot(us[0].email);
    await settle();
    assert.equal(newMail(us[0]), 1);
  });
});
