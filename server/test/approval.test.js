import assert from 'node:assert/strict';
import { generateKeyPairSync } from 'node:crypto';
import { after, before, describe, test } from 'node:test';

import {
  addDevice,
  api,
  approveDevice,
  connectWs,
  makeContacts,
  ofType,
  relaySend,
  signup,
  startServer,
} from './helpers.js';

let srv;
before(async () => {
  srv = await startServer();
});
after(() => srv.close());

describe('new-device approval', () => {
  test('a second sign-in is pending: invisible to contacts, can not send or receive', async () => {
    const a = await signup(srv.base, 'appr_a');
    const b = await signup(srv.base, 'appr_b');
    await makeContacts(srv.base, a, b);
    assert.equal((await api(srv.base, 'GET', '/api/devices/current', { token: a.token })).body.approved, true,
      'the first device is trusted');

    const aWs = await connectWs(srv.wsUrl, a.token);
    await aWs.next(ofType('hello'));
    const laptop = await addDevice(srv.base, a, { approve: false, name: 'Laptop' });
    const alert = await aWs.next(ofType('device_pending'));
    assert.equal(alert.device_id, laptop.deviceId, 'existing devices get a sign-in alert');
    assert.equal(alert.name, 'Laptop');

    const me = await api(srv.base, 'GET', '/api/devices/current', { token: laptop.token });
    assert.equal(me.body.approved, false);
    const listed = await api(srv.base, 'GET', `/api/users/${a.id}/devices`, { token: b.token });
    assert.deepEqual(listed.body.map((d) => d.device_id), [a.deviceId], 'contacts never see it');
    const mine = await api(srv.base, 'GET', '/api/devices', { token: a.token });
    assert.equal(mine.body.find((d) => d.device_id === laptop.deviceId).approved, false);

    assert.equal((await api(srv.base, 'GET', '/api/relay', { token: laptop.token })).status, 403);
    assert.equal((await relaySend(srv.base, laptop, b)).status, 403);
    const claim = await api(srv.base, 'POST', `/api/users/${b.id}/prekey-bundles`, {
      token: laptop.token,
      body: { device_ids: [b.deviceId] },
    });
    assert.equal(claim.status, 403);
    // Sending to Alice must not need to include the pending device.
    assert.equal((await relaySend(srv.base, b, a, { devices: [a.deviceId] })).status, 201);
    await aWs.close();
  });

  test('approval needs the approving device key; then the device joins', async () => {
    const a = await signup(srv.base, 'apk_a');
    const b = await signup(srv.base, 'apk_b');
    await makeContacts(srv.base, a, b);
    const laptop = await addDevice(srv.base, a, { approve: false });
    const lWs = await connectWs(srv.wsUrl, laptop.token);
    await lWs.next(ofType('hello'));

    // A stolen session token with the wrong key can't approve.
    const { privateKey: wrong } = generateKeyPairSync('ed25519');
    const forged = await approveDevice(srv.base, a, laptop, { signer: wrong });
    assert.equal(forged.status, 400);
    assert.equal(forged.body.error, 'bad_signature');
    // A pending device can't approve itself (or anyone).
    const self = await approveDevice(srv.base, laptop, laptop, { signer: laptop.deviceKeys.privateKey });
    assert.equal(self.status, 403);

    const bWs = await connectWs(srv.wsUrl, b.token);
    await bWs.next(ofType('hello'));
    const ok = await approveDevice(srv.base, a, laptop);
    assert.equal(ok.status, 200);
    await lWs.next(ofType('device_approved'));
    assert.equal((await bWs.next(ofType('devices_changed'))).user_id, a.id, 'contacts learn of it once approved');
    const listed = await api(srv.base, 'GET', `/api/users/${a.id}/devices`, { token: b.token });
    assert.equal(listed.body.length, 2);
    assert.equal((await relaySend(srv.base, b, a, { devices: [a.deviceId, laptop.deviceId] })).status, 201);
    assert.equal((await api(srv.base, 'GET', '/api/relay', { token: laptop.token })).body.length, 1);
    await lWs.close();
    await bWs.close();
  });

  test('recovery by e-mail approves this device and removes all the others', async () => {
    const a = await signup(srv.base, 'rec_a');
    const lost = await addDevice(srv.base, a); // approved
    const fresh = await addDevice(srv.base, a, { approve: false });
    assert.equal((await api(srv.base, 'POST', '/api/devices/current/recover', { token: fresh.token })).status, 202);
    const code = srv.mailer.lastCode(a.email);
    const bad = await api(srv.base, 'POST', '/api/devices/current/recover/confirm', {
      token: fresh.token,
      body: { code: code === '000000' ? '111111' : '000000' },
    });
    assert.equal(bad.status, 400);
    const ok = await api(srv.base, 'POST', '/api/devices/current/recover/confirm', {
      token: fresh.token,
      body: { code },
    });
    assert.equal(ok.status, 200);
    assert.equal(ok.body.removed_devices, 2);
    assert.equal((await api(srv.base, 'GET', '/api/me', { token: a.token })).status, 401, 'old devices signed out');
    assert.equal((await api(srv.base, 'GET', '/api/me', { token: lost.token })).status, 401);
    const devices = await api(srv.base, 'GET', '/api/devices', { token: fresh.token });
    assert.deepEqual(devices.body.map((d) => [d.device_id, d.approved]), [[fresh.deviceId, true]]);
  });

  test('re-registering a device with new keys needs approval again', async () => {
    const a = await signup(srv.base, 'rekey_a');
    const laptop = await addDevice(srv.base, a);
    const { registerDevice } = await import('./helpers.js');
    const again = await registerDevice(srv.base, laptop.token, { deviceId: laptop.deviceId });
    assert.equal(again.deviceId, laptop.deviceId);
    assert.equal((await api(srv.base, 'GET', '/api/devices/current', { token: laptop.token })).body.approved, false);
  });
});
