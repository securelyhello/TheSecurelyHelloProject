// Stories (1.1): end-to-end encrypted, gone after 24 hours.
//
// The story itself (text, or a photo/video uploaded as an encrypted
// attachment) is sealed with a per-story key; that key goes to each
// audience device inside a normal v3 envelope. The server keeps only those
// envelopes, checks who they may go to, and forgets everything at expiry.
import assert from 'node:assert/strict';
import { randomBytes, randomUUID } from 'node:crypto';
import { after, before, describe, test } from 'node:test';

import {
  addDevice,
  api,
  connectWs,
  envelopeFrom,
  makeContacts,
  ofType,
  signup,
  startServer,
} from './helpers.js';

const keysFor = (from, devices) => devices.map((d) => ({ device_id: d, envelope: envelopeFrom(from, d) }));
const post = (srv, from, keys, extra = {}) =>
  api(srv.base, 'POST', '/api/stories', { token: from.token, body: { id: randomUUID(), keys, ...extra } });
/** Uploads 500 random bytes as an encrypted attachment: {status, body}. */
async function upload(srv, who) {
  const res = await fetch(`${srv.base}/api/attachments`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${who.token}`, 'Content-Type': 'application/octet-stream' },
    body: randomBytes(500),
  });
  return { status: res.status, body: await res.json() };
}
const inbox = async (srv, who) => (await api(srv.base, 'GET', '/api/stories', { token: who.token })).body;

describe('stories', () => {
  let srv;
  let ann;
  let ben;
  let cat;
  let stranger;
  before(async () => {
    srv = await startServer({ env: { STORIES_PER_DAY: '8' } });
    ann = await signup(srv.base, 'ann');
    ben = await signup(srv.base, 'ben');
    cat = await signup(srv.base, 'cat');
    stranger = await signup(srv.base, 'stranger');
    await makeContacts(srv.base, ann, ben);
    await makeContacts(srv.base, ann, cat);
  });
  after(() => srv.close());

  test('devices say they can take stories; 1.0 devices say nothing', async () => {
    const set = await api(srv.base, 'PUT', '/api/devices/current/capabilities', {
      token: ben.token,
      body: { capabilities: ['stories'] },
    });
    assert.equal(set.status, 200);
    const devices = (await api(srv.base, 'GET', `/api/users/${ben.id}/devices`, { token: ann.token })).body;
    assert.deepEqual(devices[0].capabilities, ['stories']);
    const cats = (await api(srv.base, 'GET', `/api/users/${cat.id}/devices`, { token: ann.token })).body;
    assert.deepEqual(cats[0].capabilities, []);
    for (const bad of [['stories', 'x'.repeat(40)], 'stories', Array(20).fill('a'), ['Stories!']]) {
      const r = await api(srv.base, 'PUT', '/api/devices/current/capabilities', {
        token: ben.token,
        body: { capabilities: bad },
      });
      assert.equal(r.status, 400, JSON.stringify(bad));
    }
  });

  test('a story reaches exactly the devices it was sealed to', async () => {
    const r = await post(srv, ann, keysFor(ann, [ben.deviceId]));
    assert.equal(r.status, 201, JSON.stringify(r.body));
    assert.ok(Date.parse(r.body.expires_at) - Date.now() > 23.9 * 3600_000);
    const forBen = await inbox(srv, ben);
    const mine = forBen.find((s) => s.story_id === r.body.id);
    assert.ok(mine, 'Ben has it');
    assert.equal(mine.owner_id, ann.id);
    assert.equal(JSON.parse(mine.envelope).rd, ben.deviceId);
    assert.equal((await inbox(srv, cat)).some((s) => s.story_id === r.body.id), false, 'not in the audience');
  });

  test('only contacts (and your own devices) can be in the audience', async () => {
    const r = await post(srv, ann, keysFor(ann, [stranger.deviceId]));
    assert.equal(r.status, 403);
    assert.equal(r.body.error, 'not_contacts');
    const unknown = await post(srv, ann, keysFor(ann, [randomUUID()]));
    assert.equal(unknown.status, 403);

    const tablet = await addDevice(srv.base, ann);
    const own = await post(srv, ann, keysFor(ann, [tablet.deviceId]));
    assert.equal(own.status, 201, 'own other devices get their own stories');
  });

  test('blocking someone takes them out of the audience', async () => {
    const dan = await signup(srv.base, 'dan');
    await makeContacts(srv.base, ann, dan);
    await api(srv.base, 'POST', '/api/blocks', { token: dan.token, body: { user_id: ann.id } });
    const r = await post(srv, ann, keysFor(ann, [dan.deviceId]));
    assert.equal(r.status, 403);
  });

  test('envelopes must be well-formed and from the posting device', async () => {
    const forged = [{ device_id: ben.deviceId, envelope: envelopeFrom(cat, ben.deviceId) }];
    assert.equal((await post(srv, ann, forged)).status, 400);
    const misaddressed = [{ device_id: ben.deviceId, envelope: envelopeFrom(ann, cat.deviceId) }];
    assert.equal((await post(srv, ann, misaddressed)).status, 400);
    assert.equal((await post(srv, ann, [])).status, 400, 'no audience');
    const twice = keysFor(ann, [ben.deviceId, ben.deviceId]);
    assert.equal((await post(srv, ann, twice)).status, 400);
    const bad = await api(srv.base, 'POST', '/api/stories', {
      token: ann.token,
      body: { id: 'not-a-uuid', keys: keysFor(ann, [ben.deviceId]) },
    });
    assert.equal(bad.status, 400);
  });

  test('the same story id cannot be posted twice', async () => {
    const id = randomUUID();
    const body = { id, keys: keysFor(ann, [ben.deviceId]) };
    assert.equal((await api(srv.base, 'POST', '/api/stories', { token: ann.token, body })).status, 201);
    assert.equal((await api(srv.base, 'POST', '/api/stories', { token: ann.token, body })).status, 409);
  });

  test('a daily quota (STORIES_PER_DAY)', async () => {
    const eve = await signup(srv.base, 'eve');
    await makeContacts(srv.base, eve, ben);
    for (let i = 0; i < 8; i++) assert.equal((await post(srv, eve, keysFor(eve, [ben.deviceId]))).status, 201);
    const over = await post(srv, eve, keysFor(eve, [ben.deviceId]));
    assert.equal(over.status, 429);
    assert.equal(over.body.error, 'story_quota');
  });

  test('the owner can delete a story early; nobody else can', async () => {
    const r = await post(srv, cat, keysFor(cat, [ann.deviceId]));
    assert.equal((await api(srv.base, 'DELETE', `/api/stories/${r.body.id}`, { token: ann.token })).status, 404);
    assert.ok((await inbox(srv, ann)).some((s) => s.story_id === r.body.id));
    assert.equal((await api(srv.base, 'DELETE', `/api/stories/${r.body.id}`, { token: cat.token })).status, 200);
    assert.equal((await inbox(srv, ann)).some((s) => s.story_id === r.body.id), false);
  });

  test('photos and videos expire with their story', async () => {
    const up = await upload(srv, ann);
    assert.equal(up.status, 201);
    const theirs = await upload(srv, ben);
    const notMine = await post(srv, ann, keysFor(ann, [ben.deviceId]), { attachment_ids: [theirs.body.id] });
    assert.equal(notMine.status, 400, "someone else's upload");

    const r = await post(srv, ann, keysFor(ann, [ben.deviceId]), { attachment_ids: [up.body.id] });
    assert.equal(r.status, 201);
    const { rows } = await srv.pool.query('SELECT expires_at FROM attachments WHERE id = $1', [up.body.id]);
    assert.equal(rows[0].expires_at.toISOString(), new Date(r.body.expires_at).toISOString());
  });

  test('after 24 hours the server forgets the story and its media', async () => {
    const up = await upload(srv, ann);
    const r = await post(srv, ann, keysFor(ann, [ben.deviceId]), { attachment_ids: [up.body.id] });
    assert.equal(r.status, 201, JSON.stringify(r.body));
    // As if a day went by.
    await srv.pool.query("UPDATE stories SET expires_at = now() - interval '1 second' WHERE id = $1", [r.body.id]);
    await srv.pool.query("UPDATE attachments SET expires_at = now() - interval '1 second' WHERE id = $1", [up.body.id]);
    assert.equal((await inbox(srv, ben)).some((s) => s.story_id === r.body.id), false, 'hidden at once');
    const swept = await srv.app.sweep();
    assert.ok(swept.stories >= 1);
    const left = await srv.pool.query('SELECT count(*)::int AS n FROM story_keys WHERE story_id = $1', [r.body.id]);
    assert.equal(left.rows[0].n, 0);
    const media = await srv.pool.query('SELECT count(*)::int AS n FROM attachments WHERE id = $1', [up.body.id]);
    assert.equal(media.rows[0].n, 0);
  });

  test('audience devices hear about a new story right away', async () => {
    const ws = await connectWs(srv.wsUrl, ben.token);
    try {
      const r = await post(srv, ann, keysFor(ann, [ben.deviceId]));
      assert.equal(r.status, 201, JSON.stringify(r.body));
      const frame = await ws.next(ofType('story', (f) => f.story_id === r.body.id));
      assert.equal(frame.owner_id, ann.id);
      assert.equal(frame.envelope, undefined, 'the device fetches it; the push is only a nudge');
    } finally {
      ws.close();
    }
  });
});
