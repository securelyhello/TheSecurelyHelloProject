import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { after, before, describe, test } from 'node:test';

import { api, makeContacts, signup, startServer } from './helpers.js';

let srv;
before(async () => {
  srv = await startServer({ env: { ATTACHMENT_MAX_MB: '1', ATTACHMENT_QUOTA_MB: '2' } });
});
after(() => srv.close());

const upload = (who, bytes, type = 'application/octet-stream') =>
  fetch(`${srv.base}/api/attachments`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${who.token}`, 'Content-Type': type },
    body: bytes,
  }).then(async (r) => ({ status: r.status, body: await r.json() }));

const download = (who, id) =>
  fetch(`${srv.base}/api/attachments/${id}`, { headers: { Authorization: `Bearer ${who.token}` } }).then(
    async (r) => ({ status: r.status, type: r.headers.get('content-type'), bytes: Buffer.from(await r.arrayBuffer()) }),
  );

describe('attachments', () => {
  test('upload ciphertext; uploader and contacts can fetch it, strangers cannot', async () => {
    const a = await signup(srv.base, 'att_a');
    const b = await signup(srv.base, 'att_b');
    const stranger = await signup(srv.base, 'att_s');
    await makeContacts(srv.base, a, b);

    const blob = randomBytes(5000);
    const up = await upload(a, blob);
    assert.equal(up.status, 201);
    assert.equal(up.body.size, 5000);
    const ttl = new Date(up.body.expires_at) - Date.now();
    assert.ok(ttl > 29 * 86400_000 && ttl <= 30 * 86400_000, '30 day expiry');

    for (const who of [a, b]) {
      const got = await download(who, up.body.id);
      assert.equal(got.status, 200);
      assert.equal(got.type, 'application/octet-stream');
      assert.deepEqual(got.bytes, blob);
    }
    assert.equal((await download(stranger, up.body.id)).status, 404);

    // Only the uploader can delete it.
    assert.equal((await api(srv.base, 'DELETE', `/api/attachments/${up.body.id}`, { token: b.token })).status, 404);
    assert.equal((await api(srv.base, 'DELETE', `/api/attachments/${up.body.id}`, { token: a.token })).status, 204);
    assert.equal((await download(b, up.body.id)).status, 404);
  });

  test('size limit, quota, content type and expiry', async () => {
    const a = await signup(srv.base, 'att_lim');
    assert.equal((await upload(a, randomBytes(1024 * 1024 + 1))).status, 413);
    assert.equal((await upload(a, randomBytes(100), 'image/png')).status, 415);
    assert.equal((await upload(a, randomBytes(10))).status, 400);

    assert.equal((await upload(a, randomBytes(1000 * 1024))).status, 201);
    assert.equal((await upload(a, randomBytes(1000 * 1024))).status, 201);
    const over = await upload(a, randomBytes(200 * 1024));
    assert.equal(over.status, 413);
    assert.equal(over.body.error, 'quota_exceeded');

    const small = await upload(a, randomBytes(100));
    assert.equal(small.status, 201, 'what still fits is accepted');
    await srv.pool.query("UPDATE attachments SET expires_at = now() - interval '1 second' WHERE uploader_id = $1", [a.id]);
    const after = await upload(a, randomBytes(1000 * 1024));
    assert.equal(after.status, 201, 'expired blobs no longer count');
    const swept = await srv.app.sweep();
    assert.equal(swept.attachments, 3);
  });
});
