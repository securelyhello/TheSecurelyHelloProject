import assert from 'node:assert/strict';
import { after, before, describe, test } from 'node:test';

import { api, connectWs, makeContacts, ofType, relaySend, signup, startServer } from './helpers.js';

const ADMIN = 'a'.repeat(40);
let srv;
before(async () => {
  srv = await startServer({ env: { ADMIN_TOKEN: ADMIN } });
});
after(() => srv.close());

const block = (who, target) => api(srv.base, 'POST', '/api/blocks', { token: who.token, body: { user_id: target.id } });

describe('blocking', () => {
  test('blocking removes the contact for both and stops messages and signaling', async () => {
    const a = await signup(srv.base, 'blk_a');
    const b = await signup(srv.base, 'blk_b');
    await makeContacts(srv.base, a, b);
    const bWs = await connectWs(srv.wsUrl, b.token);
    await bWs.next(ofType('hello'));

    assert.equal((await block(a, b)).status, 201);
    assert.equal((await bWs.next(ofType('contact_removed'))).user_id, a.id, 'looks like a removal, not a block');
    assert.deepEqual((await api(srv.base, 'GET', '/api/contacts', { token: a.token })).body, []);
    assert.deepEqual((await api(srv.base, 'GET', '/api/contacts', { token: b.token })).body, []);
    assert.equal((await relaySend(srv.base, b, a)).status, 403);

    const list = await api(srv.base, 'GET', '/api/blocks', { token: a.token });
    assert.deepEqual(list.body.map((x) => x.user_id), [b.id]);
    await bWs.close();
  });

  test('the blocked user cannot find the blocker, and their requests vanish silently', async () => {
    const a = await signup(srv.base, 'sil_a');
    const b = await signup(srv.base, 'sil_b');
    await block(a, b);

    assert.equal((await api(srv.base, 'GET', `/api/users/search?q=${a.username}`, { token: b.token })).body.length, 0);
    assert.equal((await api(srv.base, 'GET', `/api/users/${a.id}`, { token: b.token })).status, 404);
    assert.equal((await api(srv.base, 'GET', `/api/users/search?q=${b.username}`, { token: a.token })).body.length, 0);

    const aWs = await connectWs(srv.wsUrl, a.token);
    await aWs.next(ofType('hello'));
    const req = await api(srv.base, 'POST', '/api/contact-requests', { token: b.token, body: { receiver_id: a.id } });
    assert.equal(req.status, 201, 'looks like a normal request to the sender');
    await aWs.none(ofType('contact_request'));
    const aRequests = await api(srv.base, 'GET', '/api/contact-requests', { token: a.token });
    assert.deepEqual(aRequests.body, [], 'never shown to the blocker');
    const accept = await api(srv.base, 'POST', `/api/contact-requests/${req.body.id}/accept`, { token: a.token });
    assert.equal(accept.status, 404);

    const mine = await api(srv.base, 'POST', '/api/contact-requests', { token: a.token, body: { receiver_id: b.id } });
    assert.equal(mine.status, 409);
    assert.equal(mine.body.error, 'blocked_by_you');
    await aWs.close();
  });

  test('unblocking lets them find each other again (the contact is not restored)', async () => {
    const a = await signup(srv.base, 'unb_a');
    const b = await signup(srv.base, 'unb_b');
    await makeContacts(srv.base, a, b);
    await block(a, b);
    assert.equal((await api(srv.base, 'DELETE', `/api/blocks/${b.id}`, { token: a.token })).status, 204);
    assert.equal((await api(srv.base, 'GET', `/api/users/search?q=${a.username}`, { token: b.token })).body.length, 1);
    assert.deepEqual((await api(srv.base, 'GET', '/api/contacts', { token: a.token })).body, []);
    await makeContacts(srv.base, a, b);
  });

  test('validation', async () => {
    const a = await signup(srv.base, 'val');
    assert.equal((await block(a, a)).status, 400);
    assert.equal(
      (await api(srv.base, 'POST', '/api/blocks', { token: a.token, body: { user_id: '00000000-0000-4000-8000-000000000000' } }))
        .status,
      404,
    );
  });
});

describe('reports and moderation', () => {
  test('a report carries only what the reporter shares; operators review and suspend', async () => {
    const a = await signup(srv.base, 'rep_a');
    const b = await signup(srv.base, 'rep_b');
    const report = await api(srv.base, 'POST', '/api/reports', {
      token: a.token,
      body: {
        user_id: b.id,
        reason: 'harassment',
        details: 'keeps sending threats',
        evidence: [{ from: 'reported', text: 'you will regret this', at: '2026-11-17T10:00:00Z' }],
      },
    });
    assert.equal(report.status, 201);
    assert.equal(
      (await api(srv.base, 'POST', '/api/reports', { token: a.token, body: { user_id: b.id, reason: 'nope' } })).status,
      400,
    );

    assert.equal((await api(srv.base, 'GET', '/api/admin/reports')).status, 404, 'hidden without the token');
    assert.equal(
      (await api(srv.base, 'GET', '/api/admin/reports', { headers: { Authorization: `Bearer ${'b'.repeat(40)}` } })).status,
      404,
    );
    const admin = { Authorization: `Bearer ${ADMIN}` };
    const open = await api(srv.base, 'GET', '/api/admin/reports', { headers: admin });
    const mine = open.body.find((r) => r.id === report.body.id);
    assert.equal(mine.reported_username, b.username);
    assert.equal(mine.evidence[0].text, 'you will regret this');

    const bWs = await connectWs(srv.wsUrl, b.token);
    await bWs.next(ofType('hello'));
    const closed = new Promise((resolve) => bWs.ws.once('close', (code) => resolve(code)));
    assert.equal((await api(srv.base, 'POST', `/api/admin/users/${b.id}/suspend`, { headers: admin })).status, 204);
    assert.equal(await closed, 4003);
    assert.equal((await api(srv.base, 'GET', '/api/me', { token: b.token })).status, 401);
    const signin = await api(srv.base, 'POST', '/api/auth/signin', { body: { email: b.email, password: b.password } });
    assert.equal(signin.status, 403);
    assert.equal(signin.body.error, 'suspended');
    assert.equal((await api(srv.base, 'GET', `/api/users/search?q=${b.username}`, { token: a.token })).body.length, 0);

    await api(srv.base, 'DELETE', `/api/admin/users/${b.id}/suspend`, { headers: admin });
    assert.equal(
      (await api(srv.base, 'POST', '/api/auth/signin', { body: { email: b.email, password: b.password } })).status,
      200,
    );
    assert.equal(
      (await api(srv.base, 'POST', `/api/admin/reports/${report.body.id}`, { headers: admin, body: { status: 'resolved' } })).status,
      204,
    );
  });
});
