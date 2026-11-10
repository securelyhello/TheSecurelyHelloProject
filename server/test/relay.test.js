import assert from 'node:assert/strict';
import { after, before, describe, test } from 'node:test';

import { api, connectWs, envelopeFrom, makeContacts, ofType, signup, startServer } from './helpers.js';

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

const send = (from, to, envelope = envelopeFrom(from.id)) =>
  api(srv.base, 'POST', '/api/relay', { token: from.token, body: { recipient_id: to.id, envelope } });

describe('relay queue', () => {
  test('offline recipient: stored, fetched on connect, deleted on ack', async () => {
    const [a, b] = await pair('store');
    const env = envelopeFrom(a.id);
    const res = await send(a, b, env);
    assert.equal(res.status, 201);
    assert.equal(res.body.pushed, false);
    const ttl = new Date(res.body.expires_at) - new Date(res.body.created_at);
    assert.ok(Math.abs(ttl - 24 * 3600_000) < 5000, '24 h expiry');

    const fetched = await api(srv.base, 'GET', '/api/relay', { token: b.token });
    assert.equal(fetched.body.length, 1);
    assert.equal(fetched.body[0].sender_id, a.id);
    assert.equal(fetched.body[0].envelope, env);

    // The sender cannot read or delete the recipient's queue.
    assert.deepEqual((await api(srv.base, 'GET', '/api/relay', { token: a.token })).body, []);
    await api(srv.base, 'POST', '/api/relay/ack', { token: a.token, body: { ids: [res.body.id] } });
    assert.equal((await api(srv.base, 'GET', '/api/relay', { token: b.token })).body.length, 1);

    const ack = await api(srv.base, 'POST', '/api/relay/ack', { token: b.token, body: { ids: [res.body.id] } });
    assert.deepEqual(ack.body, { deleted: 1 });
    assert.deepEqual((await api(srv.base, 'GET', '/api/relay', { token: b.token })).body, []);
  });

  test('connected recipient gets the envelope pushed instantly and can ack over the socket', async () => {
    const [a, b] = await pair('push');
    const bWs = await connectWs(srv.wsUrl, b.token);
    await bWs.next(ofType('hello'));
    const env = envelopeFrom(a.id);
    const res = await send(a, b, env);
    assert.equal(res.body.pushed, true);
    const pushed = await bWs.next(ofType('relay'));
    assert.equal(pushed.message.id, res.body.id);
    assert.equal(pushed.message.sender_id, a.id);
    assert.equal(pushed.message.envelope, env);

    bWs.send({ type: 'relay_ack', ids: [pushed.message.id] });
    // The ack is processed asynchronously; poll briefly.
    const key = `sh:relay:m:${res.body.id}`;
    for (let i = 0; i < 20 && (await srv.redis.exists(key)); i++) {
      await new Promise((r) => setTimeout(r, 50));
    }
    assert.equal(await srv.redis.exists(key), 0);
    assert.deepEqual((await api(srv.base, 'GET', '/api/relay', { token: b.token })).body, []);
    await bWs.close();
  });

  test('envelopes carry a native 24 h TTL and are not delivered once expired', async () => {
    const [a, b] = await pair('expire');
    const res = await send(a, b);
    const key = `sh:relay:m:${res.body.id}`;
    const ttl = await srv.redis.pttl(key);
    assert.ok(ttl > 23.9 * 3600_000 && ttl <= 24 * 3600_000, `ttl ${ttl}`);
    assert.ok((await srv.redis.pttl(`sh:relay:q:${b.id}`)) > 0, 'queue index expires too');
    // Stored value is exactly the ciphertext envelope plus routing metadata.
    const stored = JSON.parse(await srv.redis.get(key));
    assert.deepEqual(Object.keys(stored).sort(), ['created_at', 'envelope', 'id', 'recipient_id', 'sender_id']);

    // Let Redis expire it.
    await srv.redis.pexpire(key, 1);
    await new Promise((r) => setTimeout(r, 30));
    assert.deepEqual((await api(srv.base, 'GET', '/api/relay', { token: b.token })).body, []);
    assert.equal(await srv.redis.zcard(`sh:relay:q:${b.id}`), 0, 'dangling index entry pruned');
  });

  test('messages are delivered oldest first and survive until acked', async () => {
    const [a, b] = await pair('order');
    const ids = [];
    for (let i = 0; i < 3; i++) {
      ids.push((await send(a, b)).body.id);
      await new Promise((r) => setTimeout(r, 3));
    }
    const first = await api(srv.base, 'GET', '/api/relay', { token: b.token });
    assert.deepEqual(first.body.map((m) => m.id), ids);
    const again = await api(srv.base, 'GET', '/api/relay', { token: b.token });
    assert.deepEqual(again.body.map((m) => m.id), ids, 'fetch does not consume');
    await api(srv.base, 'POST', '/api/relay/ack', { token: b.token, body: { ids: ids.slice(0, 2) } });
    assert.deepEqual((await api(srv.base, 'GET', '/api/relay', { token: b.token })).body.map((m) => m.id), [ids[2]]);
  });

  test('only ciphertext envelopes from the session user, only to contacts', async () => {
    const [a, b] = await pair('authz');
    const stranger = await signup(srv.base, 'relay_stranger');

    const toStranger = await send(a, stranger);
    assert.equal(toStranger.status, 403);
    assert.equal(toStranger.body.error, 'not_contacts');

    const spoofed = await send(a, b, envelopeFrom(stranger.id));
    assert.equal(spoofed.status, 400, 'envelope sender must be the session user');

    const plaintext = await send(a, b, JSON.stringify({ v: 2, id: 'x', s: a.id, t: 1, c: 'hello in the clear' }));
    assert.equal(plaintext.status, 400);
    const extraField = await send(
      a,
      b,
      JSON.stringify({ ...JSON.parse(envelopeFrom(a.id)), body: 'hi' }),
    );
    assert.equal(extraField.status, 400);
    const notJson = await send(a, b, 'just some text');
    assert.equal(notJson.status, 400);
    const tooBig = await send(a, b, 'x'.repeat(140 * 1024));
    assert.equal(tooBig.status, 400);

    assert.deepEqual((await api(srv.base, 'GET', '/api/relay', { token: b.token })).body, []);
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
