import assert from 'node:assert/strict';
import { createVerify, generateKeyPairSync } from 'node:crypto';
import { after, before, describe, test } from 'node:test';

import { createFcmSender } from '../src/push.js';
import { api, connectWs, makeContacts, ofType, relaySend, signup, startServer } from './helpers.js';

describe('FCM sender', () => {
  const { publicKey, privateKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
  const sa = {
    project_id: 'demo-project',
    client_email: 'push@demo-project.iam.gserviceaccount.com',
    private_key: privateKey.export({ type: 'pkcs8', format: 'pem' }),
    token_uri: 'https://oauth.test/token',
  };

  test("the signed assertion only goes to Google, whatever the file's token_uri says", async () => {
    const urls = [];
    const fetchImpl = async (url) => {
      urls.push(url);
      return new Response(JSON.stringify({ access_token: 'at', expires_in: 3600 }), { status: 200 });
    };
    const evil = { ...sa, token_uri: 'https://attacker.example/token' };
    await createFcmSender(evil, { fetchImpl }).send('device-token-123', 'message');
    assert.equal(urls[0], 'https://oauth2.googleapis.com/token');
    assert.ok(!urls.includes(evil.token_uri));
  });

  test('signs a service-account JWT, caches the access token, sends no content', async () => {
    const calls = [];
    const fetchImpl = async (url, init) => {
      calls.push({ url, init });
      if (url === sa.token_uri) {
        return new Response(JSON.stringify({ access_token: 'at-1', expires_in: 3600 }), { status: 200 });
      }
      return new Response('{}', { status: 200 });
    };
    const sender = createFcmSender(sa, { fetchImpl, tokenEndpoint: sa.token_uri });
    assert.equal(await sender.send('device-token-123', 'message'), 'ok');
    assert.equal(await sender.send('device-token-123', 'request'), 'ok');
    assert.equal(calls.filter((c) => c.url === sa.token_uri).length, 1, 'access token reused');

    const assertion = new URLSearchParams(calls[0].init.body.toString()).get('assertion');
    const [h, c, sig] = assertion.split('.');
    assert.ok(createVerify('RSA-SHA256').update(`${h}.${c}`).verify(publicKey, Buffer.from(sig, 'base64url')));
    const claims = JSON.parse(Buffer.from(c, 'base64url'));
    assert.equal(claims.iss, sa.client_email);
    assert.equal(claims.scope, 'https://www.googleapis.com/auth/firebase.messaging');

    const send = calls[1];
    assert.equal(send.url, 'https://fcm.googleapis.com/v1/projects/demo-project/messages:send');
    assert.equal(send.init.headers.Authorization, 'Bearer at-1');
    const msg = JSON.parse(send.init.body).message;
    assert.equal(msg.token, 'device-token-123');
    assert.equal(msg.notification.body, 'You have a new message');
    assert.deepEqual(msg.data, { type: 'message' });
    assert.equal(JSON.parse(calls[2].init.body).message.notification.body, 'You have a new contact request');
  });

  test('UNREGISTERED tokens are reported as invalid; other errors throw', async () => {
    let status = 404;
    const fetchImpl = async (url) =>
      url === sa.token_uri
        ? new Response(JSON.stringify({ access_token: 'x', expires_in: 3600 }), { status: 200 })
        : status === 404
          ? new Response(JSON.stringify({ error: { status: 'NOT_FOUND', details: [{ errorCode: 'UNREGISTERED' }] } }), {
              status,
            })
          : new Response(JSON.stringify({ error: { status: 'UNAVAILABLE' } }), { status });
    const sender = createFcmSender(sa, { fetchImpl, tokenEndpoint: sa.token_uri });
    assert.equal(await sender.send('t'.repeat(20), 'message'), 'invalid_token');
    status = 503;
    await assert.rejects(sender.send('t'.repeat(20), 'message'), /503/);
  });
});

describe('push wake-ups', () => {
  let srv;
  const pushed = [];
  let reply = 'ok';
  before(async () => {
    srv = await startServer({
      pushSender: {
        async send(token, kind) {
          pushed.push({ token, kind });
          return reply;
        },
      },
    });
  });
  after(() => srv.close());

  const register = (who, token) =>
    api(srv.base, 'PUT', '/api/devices/current/push', { token: who.token, body: { platform: 'fcm', token } });

  test('offline devices with a token are woken; connected ones are not; throttled', async () => {
    const a = await signup(srv.base, 'push_a');
    const b = await signup(srv.base, 'push_b');
    await makeContacts(srv.base, a, b);
    const reg = await register(b, 'fcm-token-of-bob-0001');
    assert.deepEqual(reg.body, { push_enabled: true, push_available: true });
    assert.equal((await api(srv.base, 'GET', '/api/config')).body.push, true);
    const devices = await api(srv.base, 'GET', '/api/devices', { token: b.token });
    assert.equal(devices.body[0].push_enabled, true);

    pushed.length = 0;
    await relaySend(srv.base, a, b);
    await new Promise((r) => setTimeout(r, 50));
    assert.deepEqual(pushed, [{ token: 'fcm-token-of-bob-0001', kind: 'message' }]);

    await relaySend(srv.base, a, b);
    await new Promise((r) => setTimeout(r, 50));
    assert.equal(pushed.length, 1, 'throttled');

    await srv.store.clearPushSlot(b.deviceId);
    const ws = await connectWs(srv.wsUrl, b.token);
    await ws.next(ofType('hello'));
    await relaySend(srv.base, a, b);
    await new Promise((r) => setTimeout(r, 50));
    assert.equal(pushed.length, 1, 'connected devices get the socket push only');
    await ws.close();
  });

  test('contact requests wake the receiver; dead tokens are dropped', async () => {
    const a = await signup(srv.base, 'push_req_a');
    const b = await signup(srv.base, 'push_req_b');
    await register(b, 'fcm-token-dead-000001');
    pushed.length = 0;
    reply = 'invalid_token';
    await api(srv.base, 'POST', '/api/contact-requests', { token: a.token, body: { receiver_id: b.id } });
    await new Promise((r) => setTimeout(r, 100));
    assert.deepEqual(pushed, [{ token: 'fcm-token-dead-000001', kind: 'request' }]);
    const { rows } = await srv.pool.query('SELECT push_token FROM devices WHERE id = $1', [b.deviceId]);
    assert.equal(rows[0].push_token, null);
    reply = 'ok';
  });

  test('a token moves with a reinstall and can be cleared', async () => {
    const a = await signup(srv.base, 'push_move');
    const other = await signup(srv.base, 'push_move2');
    await register(a, 'shared-token-0000001');
    // Another account can't take it while [a] is signed in on that device
    // (audit run 1 hardening); after [a] signs out (reinstall) it can.
    assert.equal((await register(other, 'shared-token-0000001')).status, 409);
    assert.equal((await register(a, 'short')).status, 400);
    await api(srv.base, 'POST', '/api/auth/signout', { token: a.token });
    await register(other, 'shared-token-0000001');
    const { rows } = await srv.pool.query('SELECT id FROM devices WHERE push_token = $1', ['shared-token-0000001']);
    assert.deepEqual(rows.map((r) => r.id), [other.deviceId]);
    assert.equal((await api(srv.base, 'DELETE', '/api/devices/current/push', { token: other.token })).status, 204);
  });
});
