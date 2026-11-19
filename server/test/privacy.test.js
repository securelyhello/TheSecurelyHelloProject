// "Last seen and online" privacy (1.1): with show_presence off, nobody sees
// your online status or last seen, and (reciprocally) you see nobody's.
import assert from 'node:assert/strict';
import { after, before, describe, test } from 'node:test';

import { api, connectWs, makeContacts, ofType, signup, startServer } from './helpers.js';

describe('presence privacy', () => {
  let srv;
  let ann;
  let ben;
  before(async () => {
    srv = await startServer();
    ann = await signup(srv.base, 'pann');
    ben = await signup(srv.base, 'pben');
    await makeContacts(srv.base, ann, ben);
  });
  after(() => srv.close());

  const contactOf = async (viewer, id) =>
    (await api(srv.base, 'GET', '/api/contacts', { token: viewer.token })).body.find(
      (c) => (c.contact_user ?? c).user_id === id,
    );
  const statusOf = async (viewer, id) => {
    const c = await contactOf(viewer, id);
    return (c.contact_user ?? c).status;
  };

  test('on by default; turning it off hides both ways; on again restores', async () => {
    const me = await api(srv.base, 'GET', '/api/me', { token: ann.token });
    assert.equal(me.body.show_presence, true);

    const benWs = await connectWs(srv.wsUrl, ben.token);
    await benWs.next(ofType('hello'));
    try {
      assert.equal(await statusOf(ann, ben.id), 'online');

      const off = await api(srv.base, 'PATCH', '/api/me', { token: ann.token, body: { show_presence: false } });
      assert.equal(off.status, 200);
      assert.equal(off.body.show_presence, false);
      assert.equal(await statusOf(ann, ben.id), null, 'Ann no longer sees others');
      assert.equal(await statusOf(ben, ann.id), null, 'and nobody sees Ann');

      // No live presence about Ann either.
      const annWs = await connectWs(srv.wsUrl, ann.token);
      await annWs.next(ofType('hello'));
      await benWs.none(ofType('presence', (f) => f.user_id === ann.id), 400);
      await annWs.close();

      const bad = await api(srv.base, 'PATCH', '/api/me', { token: ann.token, body: { show_presence: 'no' } });
      assert.equal(bad.status, 400);

      await api(srv.base, 'PATCH', '/api/me', { token: ann.token, body: { show_presence: true } });
      assert.equal(await statusOf(ann, ben.id), 'online');
    } finally {
      await benWs.close();
    }
  });
});
