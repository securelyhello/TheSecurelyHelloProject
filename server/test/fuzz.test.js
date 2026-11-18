// Throws random input at every route: nothing may answer 500 or take the
// server down. Seeded, so a failure reproduces: FUZZ_SEED=<n> npm test.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { after, before, describe, test } from 'node:test';

import { api, makeContacts, signup, startServer } from './helpers.js';

const SEED = Number(process.env.FUZZ_SEED ?? 20261117);
const ROUNDS = Number(process.env.FUZZ_ROUNDS ?? 20);

// mulberry32
function prng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const FIELDS = [
  'email', 'password', 'username', 'display_name', 'code', 'otp', 'new_password', 'current_password',
  'device_id', 'signature', 'envelopes', 'known_devices', 'recipient', 'recipient_id', 'one_time_prekeys',
  'signed_prekey', 'id', 'key', 'name', 'token', 'platform', 'reason', 'details', 'evidence', 'discoverable',
  'nickname', 'ids', 'user_id', 'signing_public_key', 'identity_public_key', 'devices', 'q', 'status',
];

const NASTY = [
  '', ' ', '\u0000', '%00', '../../etc/passwd', "' OR 1=1 --", '<script>alert(1)</script>', '‮',
  '😀'.repeat(50), 'a'.repeat(5000), '-1', '1e309', 'NaN', 'null', '{}', '[]', '__proto__', 'constructor',
];

function generator(rand) {
  const pick = (xs) => xs[Math.floor(rand() * xs.length)];
  function value(depth) {
    switch (Math.floor(rand() * (depth > 2 ? 6 : 9))) {
      case 0: return null;
      case 1: return rand() < 0.5;
      case 2: return pick([0, -1, 1.5, 2 ** 53, -(2 ** 63), Number.MAX_VALUE]);
      case 3: return pick(NASTY);
      case 4: return randomUUID();
      case 5: return Buffer.from(Array.from({ length: Math.floor(rand() * 64) }, () => rand() * 256)).toString('base64');
      case 6: return Array.from({ length: Math.floor(rand() * 4) }, () => value(depth + 1));
      default: {
        const o = {};
        for (let i = Math.floor(rand() * 5); i > 0; i--) o[rand() < 0.8 ? pick(FIELDS) : pick(NASTY)] = value(depth + 1);
        return o;
      }
    }
  }
  return { value, pick };
}

describe('fuzz', () => {
  let srv;
  let me;
  let other;
  before(async () => {
    srv = await startServer();
    me = await signup(srv.base, 'fuzz_me');
    other = await signup(srv.base, 'fuzz_other');
    await makeContacts(srv.base, me, other);
  });
  after(() => srv.close());

  // DELETE /api/me and sign-out would end the fuzzing session itself.
  const routes = [
    ['POST', '/api/auth/signup'], ['POST', '/api/auth/signin'], ['POST', '/api/auth/password/forgot'],
    ['POST', '/api/auth/password/reset'], ['GET', '/api/usernames/:p/available'], ['GET', '/api/config'],
    ['POST', '/api/auth/change-password'], ['POST', '/api/auth/email/send-verification'],
    ['POST', '/api/auth/email/verify'], ['GET', '/api/me'], ['PATCH', '/api/me'], ['GET', '/api/me/2fa'],
    ['POST', '/api/me/2fa/setup'], ['POST', '/api/me/2fa/enable'], ['POST', '/api/me/2fa/disable'],
    ['POST', '/api/me/2fa/recovery-codes'], ['GET', '/api/users/search'], ['GET', '/api/users/:p'],
    ['GET', '/api/users/by-username/:p'], ['GET', '/api/users/:p/devices'], ['POST', '/api/users/:p/prekey-bundles'],
    ['GET', '/api/contact-requests'], ['POST', '/api/contact-requests'], ['POST', '/api/contact-requests/:p/accept'],
    ['POST', '/api/contact-requests/:p/reject'], ['DELETE', '/api/contact-requests/:p'], ['GET', '/api/contacts'],
    ['PATCH', '/api/contacts/:p'], ['DELETE', '/api/contacts/:p'], ['GET', '/api/devices'],
    ['GET', '/api/devices/current'], ['PUT', '/api/devices/current'], ['PATCH', '/api/devices/current'],
    ['DELETE', '/api/devices/:p'], ['POST', '/api/devices/:p/approve'], ['POST', '/api/devices/current/prekeys'],
    ['PUT', '/api/devices/current/signed-prekey'], ['PUT', '/api/devices/current/push'],
    ['DELETE', '/api/devices/current/push'], ['POST', '/api/devices/current/recover'],
    ['POST', '/api/devices/current/recover/confirm'], ['GET', '/api/relay'], ['POST', '/api/relay'],
    ['POST', '/api/relay/ack'], ['DELETE', '/api/relay/:p'], ['POST', '/api/attachments'],
    ['GET', '/api/attachments/:p'], ['DELETE', '/api/attachments/:p'], ['GET', '/api/blocks'],
    ['POST', '/api/blocks'], ['DELETE', '/api/blocks/:p'], ['POST', '/api/reports'], ['GET', '/api/admin/reports'],
    ['POST', '/api/admin/users/:p/suspend'], ['POST', '/api/invites'], ['GET', '/api/invites/:p'],
    ['POST', '/api/invites/:p/accept'], ['PUT', '/api/me/discovery'], ['POST', '/api/discovery/match'],
    ['GET', '/api/auth/challenge'],
  ];

  test(`random bodies and parameters never cause a 500 (seed ${SEED})`, async () => {
    const rand = prng(SEED);
    const { value, pick } = generator(rand);
    const params = () => pick([other.id, me.id, randomUUID(), 'x', '..%2F..', '%00', 'a'.repeat(300), '-1', other.username]);
    const failures = [];
    for (let round = 0; round < ROUNDS; round++) {
      for (const [method, pattern] of routes) {
        const path = pattern.replaceAll(':p', encodeURIComponent(params()));
        const query = method === 'GET' && rand() < 0.5 ? `?q=${encodeURIComponent(pick(NASTY))}` : '';
        const body = method === 'GET' || method === 'DELETE' ? undefined : value(0);
        const token = rand() < 0.9 ? me.token : pick([undefined, 'garbage', other.token]);
        const res = await api(srv.base, method, path + query, { token, body });
        if (res.status >= 500) failures.push(`${method} ${path + query} ${JSON.stringify(body)?.slice(0, 200)} -> ${res.status}`);
      }
    }
    assert.deepEqual(failures, []);
    assert.equal((await api(srv.base, 'GET', '/healthz')).status, 200);
    assert.equal((await api(srv.base, 'GET', '/api/me', { token: me.token })).status, 200, 'session survived');
  });

  test('malformed transport: broken JSON, wrong types, huge bodies', async () => {
    const send = (path, init) =>
      fetch(`${srv.base}${path}`, { ...init, headers: { Authorization: `Bearer ${me.token}`, ...init.headers } });
    const cases = [
      ['/api/me', { method: 'PATCH', body: '{"display_name":', headers: { 'Content-Type': 'application/json' } }],
      ['/api/me', { method: 'PATCH', body: 'display_name=x', headers: { 'Content-Type': 'application/x-www-form-urlencoded' } }],
      ['/api/relay', { method: 'POST', body: '[]'.repeat(100), headers: { 'Content-Type': 'application/json' } }],
      ['/api/relay', { method: 'POST', body: 'x'.repeat(3 * 1024 * 1024), headers: { 'Content-Type': 'application/json' } }],
      ['/api/attachments', { method: 'POST', body: '{}', headers: { 'Content-Type': 'application/json' } }],
      ['/api/me', { method: 'PATCH', body: JSON.stringify({ __proto__: { admin: true }, display_name: 'x' }), headers: { 'Content-Type': 'application/json' } }],
    ];
    for (const [path, init] of cases) {
      const res = await send(path, init).catch((e) => ({ status: 0, error: e }));
      assert.ok(res.status === 0 || res.status < 500, `${init.method} ${path} -> ${res.status}`);
    }
    assert.equal((await api(srv.base, 'GET', '/healthz')).status, 200);
  });

  test('NUL characters are refused with 400 wherever they appear', async () => {
    // Found by the fuzzer: Postgres rejected NUL in a search query with a 500.
    assert.equal((await api(srv.base, 'GET', '/api/users/search?q=a%00b', { token: me.token })).status, 400);
    assert.equal((await api(srv.base, 'PATCH', '/api/me', { token: me.token, body: { display_name: 'a\u0000b' } })).status, 400);
    assert.equal((await api(srv.base, 'PATCH', '/api/me', { token: me.token, body: { ['k\u0000']: 1 } })).status, 400);
    assert.equal((await api(srv.base, 'GET', `/api/users/by-username/a%00b`, { token: me.token })).status, 400);
  });
});
