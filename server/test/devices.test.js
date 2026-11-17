import assert from 'node:assert/strict';
import { after, before, describe, test } from 'node:test';

import {
  addDevice,
  api,
  connectWs,
  fakeKey,
  makeContacts,
  newDeviceKeys,
  ofType,
  registerDevice,
  relaySend,
  signSpk,
  signup,
  startServer,
} from './helpers.js';

let srv;
before(async () => {
  srv = await startServer();
});
after(() => srv.close());

async function pair(prefix) {
  const a = await signup(srv.base, `${prefix}_a`);
  const b = await signup(srv.base, `${prefix}_b`);
  await makeContacts(srv.base, a, b);
  return [a, b];
}

describe('devices', () => {
  test('registration binds the session to a device; the signed prekey must verify', async () => {
    const a = await signup(srv.base, 'reg', { device: false });
    const none = await api(srv.base, 'GET', '/api/devices/current', { token: a.token });
    assert.equal(none.status, 409);

    const keys = newDeviceKeys();
    const forged = await api(srv.base, 'PUT', '/api/devices/current', {
      token: a.token,
      body: { ...keys.body, signed_prekey: { ...keys.body.signed_prekey, key: fakeKey() } },
    });
    assert.equal(forged.status, 400);
    assert.equal(forged.body.error, 'bad_signature');

    const ok = await api(srv.base, 'PUT', '/api/devices/current', { token: a.token, body: { ...keys.body, name: 'Laptop' } });
    assert.equal(ok.status, 201);
    assert.equal(ok.body.prekeys_remaining, 5);
    const cur = await api(srv.base, 'GET', '/api/devices/current', { token: a.token });
    assert.equal(cur.body.device_id, ok.body.device_id);

    // Registering again on the same session updates instead of adding.
    const again = await api(srv.base, 'PUT', '/api/devices/current', { token: a.token, body: { ...keys.body, one_time_prekeys: [] } });
    assert.equal(again.status, 200);
    assert.equal(again.body.device_id, ok.body.device_id);

    const list = await api(srv.base, 'GET', '/api/devices', { token: a.token });
    assert.equal(list.body.length, 1);
    assert.equal(list.body[0].name, 'Laptop');
    assert.equal(list.body[0].current, true);
  });

  test('prekey bundles: one-time prekeys are handed out once; only for contacts or yourself', async () => {
    const [a, b] = await pair('bundle');
    const stranger = await signup(srv.base, 'bundle_stranger');
    const claim = (who, target, ids) =>
      api(srv.base, 'POST', `/api/users/${target.id}/prekey-bundles`, { token: who.token, body: { device_ids: ids } });

    const denied = await claim(stranger, b, [b.deviceId]);
    assert.equal(denied.status, 403);

    const seen = new Set();
    for (let i = 0; i < 5; i++) {
      const res = await claim(a, b, [b.deviceId]);
      assert.equal(res.status, 200);
      const [bundle] = res.body;
      assert.equal(bundle.device_id, b.deviceId);
      assert.equal(bundle.signing_public_key, b.deviceKeys.body.signing_public_key);
      assert.equal(bundle.identity_public_key, b.deviceKeys.body.identity_public_key);
      assert.deepEqual(bundle.signed_prekey, b.deviceKeys.body.signed_prekey);
      assert.ok(bundle.one_time_prekey, 'stock left');
      assert.ok(!seen.has(bundle.one_time_prekey.id), 'never handed out twice');
      seen.add(bundle.one_time_prekey.id);
    }
    const empty = await claim(a, b, [b.deviceId]);
    assert.equal(empty.body[0].one_time_prekey, null, 'out of stock: signed prekey only');

    const top = await api(srv.base, 'POST', '/api/devices/current/prekeys', {
      token: b.token,
      body: { one_time_prekeys: [{ id: 100, key: fakeKey() }] },
    });
    assert.equal(top.body.prekeys_remaining, 1);
    assert.equal((await claim(a, b, [b.deviceId])).body[0].one_time_prekey.id, 100);

    const self = await claim(a, a, [a.deviceId]);
    assert.equal(self.status, 200, 'own devices (sync sessions)');
  });

  test('devices running low on one-time prekeys are told to top up', async () => {
    const [a, b] = await pair('low');
    const bWs = await connectWs(srv.wsUrl, b.token);
    await bWs.next(ofType('hello'));
    await api(srv.base, 'POST', `/api/users/${b.id}/prekey-bundles`, { token: a.token, body: { device_ids: [b.deviceId] } });
    const low = await bWs.next(ofType('prekeys_low'));
    assert.equal(low.remaining, 4);
    await bWs.close();
  });

  test('rotating the signed prekey', async () => {
    const a = await signup(srv.base, 'rotate');
    const key = fakeKey();
    const bad = await api(srv.base, 'PUT', '/api/devices/current/signed-prekey', {
      token: a.token,
      body: { id: 2, key, signature: signSpk(a.deviceKeys.privateKey, 3, key) },
    });
    assert.equal(bad.status, 400);
    const ok = await api(srv.base, 'PUT', '/api/devices/current/signed-prekey', {
      token: a.token,
      body: { id: 2, key, signature: signSpk(a.deviceKeys.privateKey, 2, key) },
    });
    assert.equal(ok.status, 204);
    const list = await api(srv.base, 'GET', `/api/users/${a.id}/devices`, { token: a.token });
    assert.equal(list.body.length, 1);
  });

  test('adding or replacing a device tells contacts and your other devices', async () => {
    const [a, b] = await pair('announce');
    const aWs = await connectWs(srv.wsUrl, a.token);
    const bWs = await connectWs(srv.wsUrl, b.token);
    await aWs.next(ofType('hello'));
    await bWs.next(ofType('hello'));
    const b2 = await addDevice(srv.base, b);
    assert.equal((await aWs.next(ofType('devices_changed'))).user_id, b.id);
    assert.equal((await bWs.next(ofType('devices_changed'))).user_id, b.id);

    const devices = await api(srv.base, 'GET', `/api/users/${b.id}/devices`, { token: a.token });
    assert.deepEqual(devices.body.map((d) => d.device_id).sort(), [b.deviceId, b2.deviceId].sort());
    assert.equal(devices.body[0].name, undefined, "other people's device names stay private");
    await aWs.close();
    await bWs.close();
  });

  test('signing in again on the same install keeps the device', async () => {
    const a = await signup(srv.base, 'reinstall');
    await api(srv.base, 'POST', '/api/auth/signout', { token: a.token });
    const signin = await api(srv.base, 'POST', '/api/auth/signin', { body: { email: a.email, password: a.password } });
    const again = await registerDevice(srv.base, signin.body.token, { deviceId: a.deviceId });
    assert.equal(again.deviceId, a.deviceId);
    const list = await api(srv.base, 'GET', '/api/devices', { token: signin.body.token });
    assert.equal(list.body.length, 1);

    // Someone else's device id is not adopted.
    const b = await signup(srv.base, 'other_owner');
    const signinB = await api(srv.base, 'POST', '/api/auth/signin', { body: { email: b.email, password: b.password } });
    const stolen = await registerDevice(srv.base, signinB.body.token, { deviceId: a.deviceId });
    assert.notEqual(stolen.deviceId, a.deviceId);
  });

  test('unlinking a device ends its sessions and drops its queue', async () => {
    const [a, b] = await pair('unlink');
    const b2 = await addDevice(srv.base, b);
    const b2Ws = await connectWs(srv.wsUrl, b2.token);
    await b2Ws.next(ofType('hello'));
    const closed = new Promise((resolve) => b2Ws.ws.once('close', (code) => resolve(code)));
    await relaySend(srv.base, a, b, { devices: [b.deviceId, b2.deviceId] });

    const del = await api(srv.base, 'DELETE', `/api/devices/${b2.deviceId}`, { token: b.token });
    assert.equal(del.status, 204);
    assert.equal(await closed, 4004);
    assert.equal((await api(srv.base, 'GET', '/api/me', { token: b2.token })).status, 401, 'its session is gone');
    assert.equal(await srv.redis.zcard(`sh:relay:q:${b2.deviceId}`), 0);
    assert.equal((await api(srv.base, 'GET', '/api/relay', { token: b.token })).body.length, 1, 'other device untouched');

    const stale = await relaySend(srv.base, a, b, { devices: [b.deviceId, b2.deviceId] });
    assert.equal(stale.status, 409, 'senders learn the device is gone');
    assert.deepEqual(stale.body.devices, [b.deviceId]);

    const notMine = await api(srv.base, 'DELETE', `/api/devices/${b.deviceId}`, { token: a.token });
    assert.equal(notMine.status, 404);
  });

  test('a user can have at most 10 devices', async () => {
    let a = await signup(srv.base, 'many');
    for (let i = 0; i < 9; i++) a = await addDevice(srv.base, a);
    await assert.rejects(addDevice(srv.base, a), /409/);
  });
});
