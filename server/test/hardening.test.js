// Server hardening notes from security audit run 1 (docs/security-audit/run-1).
import assert from 'node:assert/strict';
import { after, before, describe, test } from 'node:test';

import { DEFAULT_LIMITS } from '../src/ratelimit.js';
import { hashToken } from '../src/security.js';
import { base32Decode, hotp, stepAt } from '../src/twofactor.js';
import { addDevice, api, makeContacts, newDeviceKeys, nextCode, mailCount, registerDevice, signup, startServer } from './helpers.js';

const ADMIN = 'a'.repeat(40);
const MIN = 60_000;
let srv;
before(async () => {
  srv = await startServer({
    env: { ADMIN_TOKEN: ADMIN },
    limitOverrides: { prekeyPair: { capacity: 3, perMs: MIN }, prekeyPairDaily: { capacity: 100, perMs: 24 * 60 * MIN } },
  });
});
after(() => srv.close());

const admin = { Authorization: `Bearer ${ADMIN}` };

describe('admin token check', () => {
  test('a non-ASCII bearer token of the same length is refused, not a 500', async () => {
    // Same string length as ADMIN, but 'é' is two bytes in UTF-8.
    for (const given of ['é'.repeat(40), `${'a'.repeat(39)}é`, 'é'.repeat(20), 'ÿ'.repeat(80)]) {
      const res = await api(srv.base, 'GET', '/api/admin/reports', { headers: { Authorization: `Bearer ${given}` } });
      assert.equal(res.status, 404, `token ${JSON.stringify(given)}`);
    }
    assert.equal((await api(srv.base, 'GET', '/api/admin/reports', { headers: admin })).status, 200);
  });
});

describe('session cache', () => {
  /**
   * Runs [revoke] while a cache-miss authenticate() of [token] sits between
   * its Postgres read and its cache write (the race in the audit note), then
   * returns what the session looks like afterwards.
   */
  async function raceAuthenticate(token, revoke) {
    const services = srv.app.services;
    await srv.store.forgetSessions([hashToken(token).toString('hex')]);
    const pool = services.pool;
    let reached;
    const atGate = new Promise((r) => (reached = r));
    let open;
    const gate = new Promise((r) => (open = r));
    let armed = true;
    services.pool = {
      query: async (...args) => {
        const res = await pool.query(...args);
        if (armed && String(args[0]).includes('last_used_at')) {
          armed = false;
          reached();
          await gate;
        }
        return res;
      },
    };
    let pending;
    try {
      pending = services.authenticate(token);
      await atGate;
    } finally {
      services.pool = pool;
    }
    await revoke();
    open();
    const first = await pending;
    assert.ok(first, 'the in-flight lookup itself started before the revocation');
    return api(srv.base, 'GET', '/api/me', { token });
  }

  test('sign-out during an in-flight lookup does not leave the token cached', async () => {
    const a = await signup(srv.base, 'race_out');
    const res = await raceAuthenticate(a.token, async () => {
      assert.equal((await api(srv.base, 'POST', '/api/auth/signout', { token: a.token })).status, 204);
    });
    assert.equal(res.status, 401);
  });

  test('password change during an in-flight lookup revokes the other session', async () => {
    const a = await signup(srv.base, 'race_pw');
    const other = await addDevice(srv.base, a);
    const res = await raceAuthenticate(other.token, async () => {
      const r = await api(srv.base, 'POST', '/api/auth/change-password', {
        token: a.token,
        body: { current_password: a.password, new_password: 'another long password 123' },
      });
      assert.equal(r.status, 204);
    });
    assert.equal(res.status, 401);
    assert.equal((await api(srv.base, 'GET', '/api/me', { token: a.token })).status, 200, 'the changing session stays');
  });

  test('password reset during an in-flight lookup revokes old sessions', async () => {
    const a = await signup(srv.base, 'race_reset');
    const before = mailCount(srv, a.email);
    assert.equal((await api(srv.base, 'POST', '/api/auth/password/forgot', { body: { email: a.email } })).status, 202);
    const code = await nextCode(srv, a.email, before);
    const res = await raceAuthenticate(a.token, async () => {
      const r = await api(srv.base, 'POST', '/api/auth/password/reset', {
        body: { email: a.email, code, new_password: 'reset long password 456' },
      });
      assert.equal(r.status, 200);
    });
    assert.equal(res.status, 401);
  });

  test('device removal during an in-flight lookup revokes its session', async () => {
    const a = await signup(srv.base, 'race_dev');
    const other = await addDevice(srv.base, a);
    const res = await raceAuthenticate(other.token, async () => {
      assert.equal((await api(srv.base, 'DELETE', `/api/devices/${other.deviceId}`, { token: a.token })).status, 204);
    });
    assert.equal(res.status, 401);
  });

  test('account deletion during an in-flight lookup revokes every session', async () => {
    const a = await signup(srv.base, 'race_del');
    const res = await raceAuthenticate(a.token, async () => {
      assert.equal((await api(srv.base, 'DELETE', '/api/me', { token: a.token, body: { current_password: a.password } })).status, 204);
    });
    assert.equal(res.status, 401);
  });

  test('suspension during an in-flight lookup rejects the cached session', async () => {
    const a = await signup(srv.base, 'race_susp');
    const res = await raceAuthenticate(a.token, async () => {
      assert.equal((await api(srv.base, 'POST', `/api/admin/users/${a.id}/suspend`, { headers: admin })).status, 204);
    });
    assert.equal(res.status, 401);
    await api(srv.base, 'DELETE', `/api/admin/users/${a.id}/suspend`, { headers: admin });
  });

  test('a suspended user is rejected on a cache hit even if the cache entry survived', async () => {
    const a = await signup(srv.base, 'susp_hit');
    assert.equal((await api(srv.base, 'GET', '/api/me', { token: a.token })).status, 200, 'cache is warm');
    const store = srv.store;
    const forget = store.forgetSessions;
    store.forgetSessions = async () => {}; // the cached entry is left behind
    try {
      assert.equal((await api(srv.base, 'POST', `/api/admin/users/${a.id}/suspend`, { headers: admin })).status, 204);
    } finally {
      store.forgetSessions = forget;
    }
    assert.ok(await store.redis.exists(`sh:sess:${hashToken(a.token).toString('hex')}`), 'entry still cached');
    assert.equal((await api(srv.base, 'GET', '/api/me', { token: a.token })).status, 401);
    await api(srv.base, 'DELETE', `/api/admin/users/${a.id}/suspend`, { headers: admin });
    const back = await api(srv.base, 'POST', '/api/auth/signin', { body: { email: a.email, password: a.password } });
    assert.equal(back.status, 200);
    assert.equal((await api(srv.base, 'GET', '/api/me', { token: back.body.token })).status, 200, 'unsuspended works');
  });

  test('a session row of a suspended user is not accepted from Postgres either', async () => {
    const a = await signup(srv.base, 'susp_db');
    await srv.pool.query('UPDATE users SET suspended_at = now() WHERE id = $1', [a.id]);
    await srv.store.forgetSessions([hashToken(a.token).toString('hex')]);
    assert.equal((await api(srv.base, 'GET', '/api/me', { token: a.token })).status, 401);
  });

  test('unrelated users keep their cached sessions working', async () => {
    const a = await signup(srv.base, 'keep_a');
    const b = await signup(srv.base, 'keep_b');
    assert.equal((await api(srv.base, 'GET', '/api/me', { token: b.token })).status, 200);
    await api(srv.base, 'POST', '/api/auth/signout', { token: a.token });
    assert.equal((await api(srv.base, 'GET', '/api/me', { token: b.token })).status, 200);
  });
});

describe('push tokens', () => {
  const setPush = (u, token) =>
    api(srv.base, 'PUT', '/api/devices/current/push', { token: u.token, body: { platform: 'fcm', token } });
  const pushOf = async (deviceId) =>
    (await srv.pool.query('SELECT push_token FROM devices WHERE id = $1', [deviceId])).rows[0].push_token;

  test("setting a push token never clears another user's device", async () => {
    const victim = await signup(srv.base, 'push_victim');
    const attacker = await signup(srv.base, 'push_attacker');
    const fcm = `fcm-token-${'x'.repeat(40)}`;
    assert.equal((await setPush(victim, fcm)).status, 200);
    const stolen = await setPush(attacker, fcm);
    assert.equal(stolen.status, 409);
    assert.equal(stolen.body.error, 'push_token_in_use');
    assert.equal(await pushOf(victim.deviceId), fcm, "the victim's device keeps its token");
    assert.equal(await pushOf(attacker.deviceId), null);
  });

  test('the next account on an install takes the token once the previous one signed out', async () => {
    const first = await signup(srv.base, 'push_first');
    const second = await signup(srv.base, 'push_second');
    const fcm = `fcm-token-${'z'.repeat(40)}`;
    assert.equal((await setPush(first, fcm)).status, 200);
    assert.equal((await api(srv.base, 'POST', '/api/auth/signout', { token: first.token })).status, 204);
    assert.equal((await setPush(second, fcm)).status, 200);
    assert.equal(await pushOf(first.deviceId), null);
    assert.equal(await pushOf(second.deviceId), fcm);
  });

  test('the token moves between devices of the same user (reinstall)', async () => {
    const a = await signup(srv.base, 'push_move');
    const other = await addDevice(srv.base, a);
    const fcm = `fcm-token-${'y'.repeat(40)}`;
    assert.equal((await setPush(a, fcm)).status, 200);
    assert.equal((await setPush(other, fcm)).status, 200);
    assert.equal(await pushOf(a.deviceId), null);
    assert.equal(await pushOf(other.deviceId), fcm);
  });
});

describe('one-time prekey claims between contacts', () => {
  const claim = (from, to) =>
    api(srv.base, 'POST', `/api/users/${to.id}/prekey-bundles`, { token: from.token, body: { device_ids: [to.deviceId] } });

  test('defaults: 10 per minute and 100 per day per requester and target', () => {
    assert.deepEqual(DEFAULT_LIMITS.prekeyPair, { capacity: 10, perMs: MIN });
    assert.deepEqual(DEFAULT_LIMITS.prekeyPairDaily, { capacity: 100, perMs: 24 * 60 * MIN });
  });

  test('past the pair limit the bundle falls back to the signed prekey only', async () => {
    const a = await signup(srv.base, 'pk_a');
    const b = await signup(srv.base, 'pk_b', { device: false });
    const d = await registerDevice(srv.base, b.token, { keys: newDeviceKeys({ prekeys: 20 }) });
    b.deviceId = d.deviceId;
    const c = await signup(srv.base, 'pk_c');
    await makeContacts(srv.base, a, b);
    await makeContacts(srv.base, c, b);

    for (let i = 0; i < 3; i++) {
      const res = await claim(a, b);
      assert.equal(res.status, 200);
      assert.ok(res.body[0].one_time_prekey, `claim ${i + 1} gets a one-time prekey`);
    }
    const over = await claim(a, b);
    assert.equal(over.status, 200, 'session setup still works');
    assert.equal(over.body.length, 1);
    assert.equal(over.body[0].one_time_prekey, null, 'no one-time prekey spent');
    assert.ok(over.body[0].signed_prekey.key, 'signed prekey fallback');
    const { rows } = await srv.pool.query('SELECT count(*)::int AS n FROM one_time_prekeys WHERE device_id = $1', [
      b.deviceId,
    ]);
    assert.equal(rows[0].n, 17, 'only three keys were spent');

    const fromC = await claim(c, b);
    assert.ok(fromC.body[0].one_time_prekey, 'another contact has its own budget');
  });

  test('claiming your own devices is not limited per pair', async () => {
    const a = await signup(srv.base, 'pk_self');
    const other = await addDevice(srv.base, a, { keys: newDeviceKeys({ prekeys: 10 }) });
    for (let i = 0; i < 5; i++) {
      const res = await api(srv.base, 'POST', `/api/users/${a.id}/prekey-bundles`, {
        token: a.token,
        body: { device_ids: [other.deviceId] },
      });
      assert.ok(res.body[0].one_time_prekey, `own claim ${i + 1}`);
    }
  });
});

describe('username change needs the password', () => {
  const patch = (u, body) => api(srv.base, 'PATCH', '/api/me', { token: u.token, body });

  test('without or with a wrong current_password it is refused', async () => {
    const a = await signup(srv.base, 'un_pw');
    const missing = await patch(a, { username: `${a.username}x`.slice(0, 30) });
    assert.equal(missing.status, 400);
    const wrong = await patch(a, { username: `${a.username}x`.slice(0, 30), current_password: 'nope nope nope' });
    assert.equal(wrong.status, 403);
    const me = await api(srv.base, 'GET', '/api/me', { token: a.token });
    assert.equal(me.body.username, a.username, 'unchanged');
    const ok = await patch(a, { username: `n${a.username}`.slice(0, 30), current_password: a.password });
    assert.equal(ok.status, 200);
    assert.equal(ok.body.username, `n${a.username}`.slice(0, 30));
  });

  test('display name and discoverability need no password', async () => {
    const a = await signup(srv.base, 'un_dn');
    assert.equal((await patch(a, { display_name: 'Fresh', discoverable: false })).status, 200);
  });

  test('with two-step verification on it also needs a code', async () => {
    const a = await signup(srv.base, 'un_2fa');
    const setup = await api(srv.base, 'POST', '/api/me/2fa/setup', { token: a.token, body: { password: a.password } });
    const secret = base32Decode(setup.body.secret);
    const en = await api(srv.base, 'POST', '/api/me/2fa/enable', { token: a.token, body: { code: hotp(secret, stepAt()) } });
    assert.equal(en.status, 200);
    const name = `t${a.username}`.slice(0, 30);
    const noCode = await patch(a, { username: name, current_password: a.password });
    assert.equal(noCode.status, 401);
    assert.equal(noCode.body.error, 'otp_required');
    const ok = await patch(a, { username: name, current_password: a.password, otp: hotp(secret, stepAt() + 1) });
    assert.equal(ok.status, 200);
    assert.equal(ok.body.username, name);
  });
});

describe('account deletion needs the password', () => {
  const del = (u, body) => api(srv.base, 'DELETE', '/api/me', { token: u.token, body });
  const alive = async (u) => (await api(srv.base, 'GET', '/api/me', { token: u.token })).status === 200;

  test('without a password it is refused with 400', async () => {
    const a = await signup(srv.base, 'del_nopw');
    assert.equal((await del(a)).status, 400);
    assert.equal((await del(a, {})).status, 400);
    assert.equal((await del(a, { current_password: 42 })).status, 400);
    assert.equal(await alive(a), true, 'still there');
  });

  test('with a wrong password it is refused with 403 invalid_credentials', async () => {
    const a = await signup(srv.base, 'del_wrong');
    const wrong = await del(a, { current_password: 'nope nope nope' });
    assert.equal(wrong.status, 403);
    assert.equal(wrong.body.error, 'invalid_credentials');
    assert.equal(await alive(a), true, 'still there');
  });

  test('with two-step verification on it also needs a code', async () => {
    const a = await signup(srv.base, 'del_2fa');
    const setup = await api(srv.base, 'POST', '/api/me/2fa/setup', { token: a.token, body: { password: a.password } });
    const secret = base32Decode(setup.body.secret);
    const en = await api(srv.base, 'POST', '/api/me/2fa/enable', { token: a.token, body: { code: hotp(secret, stepAt()) } });
    assert.equal(en.status, 200);
    const noCode = await del(a, { current_password: a.password });
    assert.equal(noCode.status, 401);
    assert.equal(noCode.body.error, 'otp_required');
    assert.equal(await alive(a), true, 'still there');
    const ok = await del(a, { current_password: a.password, otp: hotp(secret, stepAt() + 1) });
    assert.equal(ok.status, 204);
    assert.equal(await alive(a), false, 'deleted');
  });

  test('with the right password the account is deleted', async () => {
    const a = await signup(srv.base, 'del_ok');
    assert.equal((await del(a, { current_password: a.password })).status, 204);
    assert.equal(await alive(a), false);
    const { rows } = await srv.pool.query('SELECT count(*)::int AS n FROM users WHERE id = $1', [a.id]);
    assert.equal(rows[0].n, 0);
  });
});
