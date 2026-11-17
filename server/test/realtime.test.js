import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { after, before, describe, test } from 'node:test';

import WebSocket from 'ws';

import { api, connectWs, makeContacts, ofType, signup, startServer } from './helpers.js';

let srv;
before(async () => {
  srv = await startServer({ limitOverrides: { wsFrames: { capacity: 50, perMs: 60_000 } } });
});
after(() => srv.close());

async function pair(prefix) {
  const a = await signup(srv.base, `${prefix}_a`);
  const b = await signup(srv.base, `${prefix}_b`);
  await makeContacts(srv.base, a, b);
  return [a, b];
}

describe('websocket', () => {
  test('connection requires a valid session token', async () => {
    await assert.rejects(connectWs(srv.wsUrl), /401/);
    await assert.rejects(connectWs(srv.wsUrl, 'A'.repeat(43)), /401/);
    const a = await signup(srv.base, 'wsauth');
    await assert.rejects(connectWs(srv.wsUrl.replace('/api/ws', '/nope'), a.token), /404/);
    const ws = await connectWs(srv.wsUrl, a.token);
    const hello = await ws.next(ofType('hello'));
    assert.equal(hello.user_id, a.id);
    assert.deepEqual(hello.online, []);

    // A revoked session can no longer open sockets.
    await api(srv.base, 'POST', '/api/auth/signout', { token: a.token });
    await assert.rejects(connectWs(srv.wsUrl, a.token), /401/);
    await ws.close();
  });

  test('offer / answer / ICE are forwarded live between contacts with a server-set sender', async () => {
    const [a, b] = await pair('sig');
    const aWs = await connectWs(srv.wsUrl, a.token);
    const bWs = await connectWs(srv.wsUrl, b.token);
    await aWs.next(ofType('hello'));
    const bHello = await bWs.next(ofType('hello'));
    assert.deepEqual(bHello.online, [a.id], 'hello lists online contacts');

    const session = randomUUID();
    // `from` in the client frame is ignored; the server stamps the real sender.
    aWs.send({ type: 'signal', to: b.id, session_id: session, kind: 'offer', sdp: 'v=0 offer', from: b.id });
    const offer = await bWs.next(ofType('signal'));
    assert.deepEqual(offer, { type: 'signal', from: a.id, session_id: session, kind: 'offer', sdp: 'v=0 offer' });

    // ICE sent before the answer is still delivered, in order.
    aWs.send({
      type: 'signal',
      to: b.id,
      session_id: session,
      kind: 'ice',
      candidate: { candidate: 'candidate:1 1 udp 1 10.0.0.1 9 typ host', sdpMid: '0', sdpMLineIndex: 0 },
    });
    const ice = await bWs.next(ofType('signal', (f) => f.kind === 'ice'));
    assert.equal(ice.from, a.id);
    assert.equal(ice.candidate.sdpMLineIndex, 0);

    bWs.send({ type: 'signal', to: a.id, session_id: session, kind: 'answer', sdp: 'v=0 answer' });
    const answer = await aWs.next(ofType('signal', (f) => f.kind === 'answer'));
    assert.equal(answer.from, b.id);
    assert.equal(answer.sdp, 'v=0 answer');

    bWs.send({ type: 'signal', to: a.id, session_id: session, kind: 'bye', reason: 'timeout' });
    const bye = await aWs.next(ofType('signal', (f) => f.kind === 'bye'));
    assert.equal(bye.reason, 'timeout');

    // Nothing about signaling is persisted.
    const { rows } = await srv.pool.query(
      `SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' ORDER BY 1`,
    );
    assert.deepEqual(
      rows.map((r) => r.table_name),
      ['contact_requests', 'contacts', 'email_codes', 'schema_migrations', 'sessions', 'users'],
    );
    await aWs.close();
    await bWs.close();
  });

  test('signaling to an offline contact reports offline; to a stranger reports not_contacts', async () => {
    const [a, b] = await pair('sigoff');
    const stranger = await signup(srv.base, 'stranger');
    const sWs = await connectWs(srv.wsUrl, stranger.token);
    const aWs = await connectWs(srv.wsUrl, a.token);
    await aWs.next(ofType('hello'));

    const s1 = randomUUID();
    aWs.send({ type: 'signal', to: b.id, session_id: s1, kind: 'offer', sdp: 'x' });
    const off = await aWs.next(ofType('signal_error'));
    assert.deepEqual(off, { type: 'signal_error', to: b.id, session_id: s1, reason: 'offline' });

    const s2 = randomUUID();
    aWs.send({ type: 'signal', to: stranger.id, session_id: s2, kind: 'offer', sdp: 'x' });
    const nc = await aWs.next(ofType('signal_error'));
    assert.equal(nc.reason, 'not_contacts');
    await sWs.none(ofType('signal'));
    await aWs.close();
    await sWs.close();
  });

  test('malformed and oversized frames are rejected; frame rate is limited', async () => {
    const [a, b] = await pair('frames');
    const aWs = await connectWs(srv.wsUrl, a.token);
    await aWs.next(ofType('hello'));
    aWs.ws.send('not json');
    assert.equal((await aWs.next(ofType('error'))).code, 'malformed_json');
    aWs.send({ type: 'nope' });
    assert.equal((await aWs.next(ofType('error'))).code, 'unknown_type');
    aWs.send({ type: 'signal', to: 'x', session_id: randomUUID(), kind: 'offer', sdp: 'x' });
    assert.equal((await aWs.next(ofType('error'))).code, 'invalid_signal');
    aWs.send({ type: 'signal', to: a.id, session_id: randomUUID(), kind: 'offer', sdp: 'x' });
    assert.equal((await aWs.next(ofType('error'))).code, 'invalid_signal', 'cannot signal yourself');
    aWs.send({ type: 'signal', to: b.id, session_id: randomUUID(), kind: 'offer', sdp: 'x'.repeat(40_000) });
    assert.equal((await aWs.next(ofType('error'))).code, 'invalid_signal');
    aWs.send({ type: 'signal', to: b.id, session_id: randomUUID(), kind: 'ice', candidate: { candidate: 5 } });
    assert.equal((await aWs.next(ofType('error'))).code, 'invalid_signal');

    // > maxPayload (64 KiB): the server closes the socket (1009).
    const closed = new Promise((resolve) => aWs.ws.once('close', (code) => resolve(code)));
    aWs.ws.send('x'.repeat(70 * 1024));
    assert.equal(await closed, 1009);

    // Rate limit (capacity 50 in this file).
    const cWs = await connectWs(srv.wsUrl, b.token);
    await cWs.next(ofType('hello'));
    for (let i = 0; i < 60; i++) cWs.send({ type: 'ping' });
    const limited = await cWs.next(ofType('error', (f) => f.code === 'rate_limited'));
    assert.equal(limited.code, 'rate_limited');
    await cWs.close();
  });

  test('presence: contacts see online on connect, offline + last_seen on disconnect, and away', async () => {
    const [a, b] = await pair('presence');
    const aWs = await connectWs(srv.wsUrl, a.token);
    await aWs.next(ofType('hello'));

    const bWs = await connectWs(srv.wsUrl, b.token);
    const on = await aWs.next(ofType('presence', (f) => f.user_id === b.id));
    assert.equal(on.online, true);

    const contacts = await api(srv.base, 'GET', '/api/contacts', { token: a.token });
    assert.equal(contacts.body[0].contact_user.status, 'online');

    bWs.send({ type: 'presence', state: 'away' });
    const away = await aWs.next(ofType('presence', (f) => f.user_id === b.id));
    assert.equal(away.online, false);
    bWs.send({ type: 'presence', state: 'online' });
    assert.equal((await aWs.next(ofType('presence', (f) => f.user_id === b.id))).online, true);

    await bWs.close();
    const offline = await aWs.next(ofType('presence', (f) => f.user_id === b.id));
    assert.equal(offline.online, false);
    assert.ok(offline.last_seen, 'last_seen is set on disconnect');
    const after = await api(srv.base, 'GET', '/api/contacts', { token: a.token });
    assert.equal(after.body[0].contact_user.status, 'offline');
    assert.ok(after.body[0].contact_user.last_seen);
    await aWs.close();
  });

  test('two devices of one user: presence stays online until the last socket closes', async () => {
    const [a, b] = await pair('multi');
    const aWs = await connectWs(srv.wsUrl, a.token);
    await aWs.next(ofType('hello'));
    const b1 = await connectWs(srv.wsUrl, b.token);
    const b2 = await connectWs(srv.wsUrl, b.token);
    assert.equal((await aWs.next(ofType('presence'))).online, true);
    await b1.close();
    await aWs.none(ofType('presence'));
    await b2.close();
    assert.equal((await aWs.next(ofType('presence'))).online, false);
    await aWs.close();
  });

  test('keys_changed is pushed to contacts', async () => {
    const [a, b] = await pair('keys');
    const aWs = await connectWs(srv.wsUrl, a.token);
    await aWs.next(ofType('hello'));
    const k = { signing_public_key: b.encryption_public_key, encryption_public_key: b.signing_public_key };
    await api(srv.base, 'PUT', '/api/me/keys', { token: b.token, body: k });
    assert.equal((await aWs.next(ofType('keys_changed'))).user_id, b.id);
    await aWs.close();
  });

  test('deleting an account closes its sockets', async () => {
    const a = await signup(srv.base, 'wsdel');
    const ws = await connectWs(srv.wsUrl, a.token);
    await ws.next(ofType('hello'));
    const closed = new Promise((resolve) => ws.ws.once('close', (code) => resolve(code)));
    await api(srv.base, 'DELETE', '/api/me', { token: a.token });
    assert.equal(await closed, 4003);
    assert.equal(ws.ws.readyState, WebSocket.CLOSED);
  });
});
