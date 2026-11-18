import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { after, before, describe, test } from 'node:test';

import { addDevice, api, connectWs, makeContacts, ofType, relaySend, signup, startSecondInstance, startServer } from './helpers.js';

// Two server instances on one Postgres and Redis, as behind a load balancer.
let one;
let two;
before(async () => {
  one = await startServer();
  two = await startSecondInstance(one);
});
after(async () => {
  await two.close();
  await one.close();
});

async function pair(tag) {
  const a = await signup(one.base, `${tag}_a`);
  const b = await signup(one.base, `${tag}_b`);
  await makeContacts(one.base, a, b);
  return [a, b];
}

describe('several server instances', () => {
  test('relay pushes, signaling and presence cross instances', async () => {
    const [a, b] = await pair('x');
    const aWs = await connectWs(one.wsUrl, a.token);
    await aWs.next(ofType('hello'));
    const bWs = await connectWs(two.wsUrl, b.token);
    const hello = await bWs.next(ofType('hello'));
    assert.deepEqual(hello.online, [a.id], 'presence is shared');
    const online = await aWs.next(ofType('presence', (f) => f.user_id === b.id));
    assert.equal(online.online, true, 'B coming online on instance two reaches A on instance one');

    // A sends through instance one; B's socket is on instance two.
    const sent = await relaySend(one.base, a, b);
    assert.equal(sent.status, 201);
    assert.equal(sent.body.messages[0].pushed, true, 'counted as delivered live, so no push wake');
    const relay = await bWs.next(ofType('relay'));
    assert.equal(relay.message.sender_id, a.id);

    const session = randomUUID();
    aWs.send({ type: 'signal', to: b.id, to_device: b.deviceId, session_id: session, kind: 'offer', sdp: 'v=0' });
    const offer = await bWs.next(ofType('signal'));
    assert.equal(offer.session_id, session);
    assert.equal(offer.from, a.id);

    await bWs.close();
    const offline = await aWs.next(ofType('presence', (f) => f.user_id === b.id));
    assert.equal(offline.online, false);
    await aWs.close();
  });

  test('a user is online while any instance holds one of their sockets', async () => {
    const [a, b] = await pair('y');
    const phone = await connectWs(one.wsUrl, b.token);
    await phone.next(ofType('hello'));
    const laptop = await addDevice(one.base, b);
    const laptopWs = await connectWs(two.wsUrl, laptop.token);
    await laptopWs.next(ofType('hello'));

    const aWs = await connectWs(one.wsUrl, a.token);
    await aWs.next(ofType('hello'));
    await phone.close();
    await aWs.none(ofType('presence', (f) => f.user_id === b.id && !f.online), 500);
    await laptopWs.close();
    const offline = await aWs.next(ofType('presence', (f) => f.user_id === b.id));
    assert.equal(offline.online, false, 'offline once the last socket, on the other instance, closed');
    await aWs.close();
  });

  test('removing a device closes its socket on another instance', async () => {
    const [a] = await pair('z');
    const laptop = await addDevice(one.base, a);
    const ws = await connectWs(two.wsUrl, laptop.token);
    await ws.next(ofType('hello'));
    const closed = new Promise((resolve) => ws.ws.once('close', (code) => resolve(code)));
    const res = await api(one.base, 'DELETE', `/api/devices/${laptop.deviceId}`, { token: a.token });
    assert.equal(res.status, 204);
    assert.equal(await closed, 4004);
  });
});
