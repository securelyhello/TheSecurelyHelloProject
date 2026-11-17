import assert from 'node:assert/strict';
import { after, before, describe, test } from 'node:test';

import {
  addDevice,
  api,
  connectWs,
  envelopeFrom,
  makeContacts,
  ofType,
  relaySend,
  signup,
  startServer,
} from './helpers.js';

let srv;
before(async () => {
  srv = await startServer({ limitOverrides: { relay: { capacity: 30, perMs: 60_000 } } });
});
after(() => srv.close());

async function pair(prefix) {
  const a = await signup(srv.base, `${prefix}_a`);
  const b = await signup(srv.base, `${prefix}_b`);
  await makeContacts(srv.base, a, b);
  return [a, b];
}

const send = (from, to, opts) => relaySend(srv.base, from, to, opts);
const fetchQueue = (who) => api(srv.base, 'GET', '/api/relay', { token: who.token });

describe('relay queue', () => {
  test('offline recipient: stored per device, fetched on connect, deleted on ack', async () => {
    const [a, b] = await pair('store');
    const env = envelopeFrom(a, b.deviceId);
    const res = await send(a, b, { envelopes: [env] });
    assert.equal(res.status, 201);
    const [m] = res.body.messages;
    assert.equal(m.device_id, b.deviceId);
    assert.equal(m.pushed, false);

    const fetched = await fetchQueue(b);
    assert.equal(fetched.body.length, 1);
    assert.equal(fetched.body[0].sender_id, a.id);
    assert.equal(fetched.body[0].sender_device, a.deviceId);
    assert.equal(fetched.body[0].envelope, env);

    // The sender cannot read or delete the recipient's queue.
    assert.deepEqual((await fetchQueue(a)).body, []);
    await api(srv.base, 'POST', '/api/relay/ack', { token: a.token, body: { ids: [m.id] } });
    assert.equal((await fetchQueue(b)).body.length, 1);

    const ack = await api(srv.base, 'POST', '/api/relay/ack', { token: b.token, body: { ids: [m.id] } });
    assert.deepEqual(ack.body, { deleted: 1 });
    assert.deepEqual((await fetchQueue(b)).body, []);
  });

  test('each device has its own queue', async () => {
    const [a, b] = await pair('multi');
    const b2 = await addDevice(srv.base, b, { name: 'tablet' });
    const devices = [b.deviceId, b2.deviceId];
    const res = await send(a, b, { devices });
    assert.equal(res.status, 201);
    assert.equal(res.body.messages.length, 2);
    const q1 = (await fetchQueue(b)).body;
    const q2 = (await fetchQueue(b2)).body;
    assert.equal(q1.length, 1);
    assert.equal(q2.length, 1);
    assert.notEqual(q1[0].envelope, q2[0].envelope, 'a separate envelope per device');
    assert.equal(JSON.parse(q2[0].envelope).rd, b2.deviceId);
    // Acking on one device does not touch the other's copy.
    await api(srv.base, 'POST', '/api/relay/ack', { token: b.token, body: { ids: [q1[0].id] } });
    assert.equal((await fetchQueue(b2)).body.length, 1);
  });

  test('a stale device list is refused with the current one (no device is skipped)', async () => {
    const [a, b] = await pair('stale');
    const b2 = await addDevice(srv.base, b);
    const res = await send(a, b, { devices: [b.deviceId] });
    assert.equal(res.status, 409);
    assert.equal(res.body.error, 'devices_changed');
    assert.deepEqual(res.body.devices.sort(), [b.deviceId, b2.deviceId].sort());
    assert.deepEqual((await fetchQueue(b)).body, [], 'nothing was queued');

    // Known list complete, envelopes for a subset (the rest went over WebRTC).
    const partial = await send(a, b, { devices: [b2.deviceId], known: [b.deviceId, b2.deviceId] });
    assert.equal(partial.status, 201);
    assert.equal((await fetchQueue(b2)).body.length, 1);
    assert.equal((await fetchQueue(b)).body.length, 0);

    const notKnown = await send(a, b, { devices: [b2.deviceId], known: [b.deviceId] });
    assert.equal(notKnown.status, 409);
  });

  test('sync copies to your own other devices; never to the sending device', async () => {
    const a = await signup(srv.base, 'self');
    const a2 = await addDevice(srv.base, a);
    const res = await send(a, a, { devices: [a2.deviceId] });
    assert.equal(res.status, 201);
    assert.equal((await fetchQueue(a2)).body.length, 1);
    const wrong = await send(a, a, { devices: [a.deviceId, a2.deviceId] });
    assert.equal(wrong.status, 409, 'the sending device is not a recipient');
  });

  test('connected device gets the envelope pushed instantly and can ack over the socket', async () => {
    const [a, b] = await pair('push');
    const b2 = await addDevice(srv.base, b);
    const bWs = await connectWs(srv.wsUrl, b.token);
    const b2Ws = await connectWs(srv.wsUrl, b2.token);
    await bWs.next(ofType('hello'));
    assert.equal((await b2Ws.next(ofType('hello'))).device_id, b2.deviceId);
    const res = await send(a, b, { devices: [b.deviceId, b2.deviceId] });
    assert.ok(res.body.messages.every((m) => m.pushed));
    const pushed = await bWs.next(ofType('relay'));
    const pushed2 = await b2Ws.next(ofType('relay'));
    assert.equal(JSON.parse(pushed.message.envelope).rd, b.deviceId, 'each socket gets only its own copy');
    assert.equal(JSON.parse(pushed2.message.envelope).rd, b2.deviceId);
    assert.equal(pushed.message.sender_device, a.deviceId);

    bWs.send({ type: 'relay_ack', ids: [pushed.message.id] });
    const key = `sh:relay:m:${pushed.message.id}`;
    for (let i = 0; i < 20 && (await srv.redis.exists(key)); i++) {
      await new Promise((r) => setTimeout(r, 50));
    }
    assert.equal(await srv.redis.exists(key), 0);
    assert.equal((await fetchQueue(b2)).body.length, 1);
    await bWs.close();
    await b2Ws.close();
  });

  test('envelopes carry a native 24 h TTL and are not delivered once expired', async () => {
    const [a, b] = await pair('expire');
    const res = await send(a, b);
    const id = res.body.messages[0].id;
    const key = `sh:relay:m:${id}`;
    const ttl = await srv.redis.pttl(key);
    assert.ok(ttl > 23.9 * 3600_000 && ttl <= 24 * 3600_000, `ttl ${ttl}`);
    assert.ok((await srv.redis.pttl(`sh:relay:q:${b.deviceId}`)) > 0, 'queue index expires too');
    const stored = JSON.parse(await srv.redis.get(key));
    assert.deepEqual(Object.keys(stored).sort(), [
      'created_at',
      'envelope',
      'id',
      'recipient_device',
      'recipient_id',
      'sender_device',
      'sender_id',
    ]);
    await srv.redis.pexpire(key, 1);
    await new Promise((r) => setTimeout(r, 30));
    assert.deepEqual((await fetchQueue(b)).body, []);
    assert.equal(await srv.redis.zcard(`sh:relay:q:${b.deviceId}`), 0, 'dangling index entry pruned');
  });

  test('messages are delivered oldest first and survive until acked', async () => {
    const [a, b] = await pair('order');
    const ids = [];
    for (let i = 0; i < 3; i++) {
      ids.push((await send(a, b)).body.messages[0].id);
      await new Promise((r) => setTimeout(r, 3));
    }
    const first = await fetchQueue(b);
    assert.deepEqual(first.body.map((m) => m.id), ids);
    const again = await fetchQueue(b);
    assert.deepEqual(again.body.map((m) => m.id), ids, 'fetch does not consume');
    await api(srv.base, 'POST', '/api/relay/ack', { token: b.token, body: { ids: ids.slice(0, 2) } });
    assert.deepEqual((await fetchQueue(b)).body.map((m) => m.id), [ids[2]]);
  });

  test('only ciphertext envelopes from the session device, only to contacts', async () => {
    const [a, b] = await pair('authz');
    const stranger = await signup(srv.base, 'relay_stranger');
    const one = (env) => send(a, b, { envelopes: [env] });

    const toStranger = await send(a, stranger);
    assert.equal(toStranger.status, 403);
    assert.equal(toStranger.body.error, 'not_contacts');

    assert.equal((await one(envelopeFrom(stranger, b.deviceId, { sd: a.deviceId }))).status, 400, 'sender user');
    assert.equal((await one(envelopeFrom(a, b.deviceId, { sd: stranger.deviceId }))).status, 400, 'sender device');
    assert.equal((await one(envelopeFrom(a, a.deviceId))).status, 400, 'recipient device');
    assert.equal((await one(envelopeFrom(a, b.deviceId, { v: 2 }))).status, 400, 'old version');
    assert.equal((await one(envelopeFrom(a, b.deviceId, { c: 'hello in the clear' }))).status, 400);
    assert.equal((await one(JSON.stringify({ ...JSON.parse(envelopeFrom(a, b.deviceId)), body: 'hi' }))).status, 400);
    assert.equal((await one('just some text')).status, 400);
    assert.equal((await one('x'.repeat(140 * 1024))).status, 400);

    const noDevice = await signup(srv.base, 'nodev', { device: false });
    const res = await api(srv.base, 'GET', '/api/relay', { token: noDevice.token });
    assert.equal(res.status, 409);
    assert.equal(res.body.error, 'no_device');

    assert.deepEqual((await fetchQueue(b)).body, []);
  });

  test('relay sends are rate limited per sender', async () => {
    const [a, b] = await pair('rl');
    const codes = [];
    for (let i = 0; i < 40; i++) codes.push((await send(a, b)).status);
    assert.ok(codes.includes(429), JSON.stringify(codes));
  });

  test('removing a contact invalidates the cached contact check immediately', async () => {
    const [a, b] = await pair('cache');
    assert.equal((await send(b, a)).status, 201); // warms the contact cache
    await api(srv.base, 'DELETE', `/api/contacts/${a.id}`, { token: b.token });
    assert.equal((await send(b, a)).status, 403);
    assert.equal((await send(a, b)).status, 403);
  });

  test('a full recipient queue is refused instead of dropping messages', async () => {
    const [a, b] = await pair('full');
    const small = srv.store.relayQueueCap;
    srv.store.relayQueueCap = 2;
    try {
      assert.equal((await send(b, a)).status, 201);
      assert.equal((await send(b, a)).status, 201);
      const third = await send(b, a);
      assert.equal(third.status, 429);
      assert.equal(third.body.error, 'recipient_queue_full');
    } finally {
      srv.store.relayQueueCap = small;
    }
  });
});
