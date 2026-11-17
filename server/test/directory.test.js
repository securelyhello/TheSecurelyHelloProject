import assert from 'node:assert/strict';
import { after, before, describe, test } from 'node:test';

import { api, connectWs, makeContacts, ofType, signup, startServer } from './helpers.js';

let srv;
before(async () => {
  srv = await startServer();
});
after(() => srv.close());

describe('directory', () => {
  test('me, profile update; keys live on devices, not the profile', async () => {
    const a = await signup(srv.base, 'me');
    const me = await api(srv.base, 'GET', '/api/me', { token: a.token });
    assert.equal(me.body.user_id, a.id);
    assert.equal(me.body.signing_public_key, undefined);
    assert.equal(me.body.password_hash, undefined);

    const patched = await api(srv.base, 'PATCH', '/api/me', { token: a.token, body: { display_name: '  New Name ' } });
    assert.equal(patched.body.display_name, 'New Name');
    assert.equal((await api(srv.base, 'PATCH', '/api/me', { token: a.token, body: {} })).status, 400);
    assert.equal((await api(srv.base, 'PUT', '/api/me/keys', { token: a.token, body: {} })).status, 404);
  });

  test('API responses forbid caching, framing and active content', async () => {
    const a = await signup(srv.base, 'hdrs');
    const res = await fetch(`${srv.base}/api/me`, { headers: { Authorization: `Bearer ${a.token}` } });
    assert.equal(res.headers.get('cache-control'), 'no-store');
    assert.equal(res.headers.get('x-content-type-options'), 'nosniff');
    assert.equal(res.headers.get('x-frame-options'), 'DENY');
    assert.match(res.headers.get('content-security-policy'), /default-src 'none'/);
  });

  test('turning discovery off hides you from partial search but not exact username', async () => {
    const a = await signup(srv.base, 'seeker');
    const b = await signup(srv.base, 'hiddenperson');
    const off = await api(srv.base, 'PATCH', '/api/me', { token: b.token, body: { discoverable: false } });
    assert.equal(off.body.discoverable, false);
    assert.equal((await api(srv.base, 'PATCH', '/api/me', { token: b.token, body: { discoverable: 'no' } })).status, 400);

    const partial = await api(srv.base, 'GET', '/api/users/search?q=hiddenpers', { token: a.token });
    assert.equal(partial.body.some((u) => u.user_id === b.id), false);
    const exact = await api(srv.base, 'GET', `/api/users/search?q=${b.username}`, { token: a.token });
    assert.ok(exact.body.some((u) => u.user_id === b.id));
    assert.equal(exact.body.find((u) => u.user_id === b.id).discoverable, undefined, 'setting not exposed');
  });

  test('search excludes self, escapes wildcards, hides presence from strangers', async () => {
    const a = await signup(srv.base, 'searcher');
    const b = await signup(srv.base, 'findme');
    const res = await api(srv.base, 'GET', '/api/users/search?q=FINDME', { token: a.token });
    assert.equal(res.status, 200);
    assert.ok(res.body.some((u) => u.user_id === b.id));
    assert.equal(res.body.find((u) => u.user_id === b.id).status, null, 'presence hidden from non-contacts');
    assert.equal(res.body.find((u) => u.user_id === b.id).email, undefined, 'email never exposed');

    const self = await api(srv.base, 'GET', `/api/users/search?q=${a.username}`, { token: a.token });
    assert.equal(self.body.some((u) => u.user_id === a.id), false);

    const wildcard = await api(srv.base, 'GET', '/api/users/search?q=%25', { token: a.token });
    assert.deepEqual(wildcard.body, [], '% is matched literally');
    const underscore = await api(srv.base, 'GET', '/api/users/search?q=_', { token: a.token });
    assert.ok(underscore.body.every((u) => u.username.includes('_')));
    assert.equal((await api(srv.base, 'GET', '/api/users/search?q=', { token: a.token })).status, 400);
    assert.equal((await api(srv.base, 'GET', '/api/users/search?q=abc', {})).status, 401);
  });

  test('lookup by id and username', async () => {
    const a = await signup(srv.base, 'lookup_a');
    const b = await signup(srv.base, 'lookup_b');
    const byId = await api(srv.base, 'GET', `/api/users/${b.id}`, { token: a.token });
    assert.equal(byId.body.username, b.username);
    const byName = await api(srv.base, 'GET', `/api/users/by-username/${b.username}`, { token: a.token });
    assert.equal(byName.body.user_id, b.id);
    assert.equal((await api(srv.base, 'GET', '/api/users/not-a-uuid', { token: a.token })).status, 400);
    assert.equal(
      (await api(srv.base, 'GET', '/api/users/00000000-0000-4000-8000-000000000000', { token: a.token })).status,
      404,
    );
  });
});

describe('contact requests', () => {
  test('send → pending on both sides → accept → contacts on both sides', async () => {
    const a = await signup(srv.base, 'req_a');
    const b = await signup(srv.base, 'req_b');
    const bWs = await connectWs(srv.wsUrl, b.token);
    const aWs = await connectWs(srv.wsUrl, a.token);
    await bWs.next(ofType('hello'));
    await aWs.next(ofType('hello'));

    const sent = await api(srv.base, 'POST', '/api/contact-requests', { token: a.token, body: { receiver_id: b.id } });
    assert.equal(sent.status, 201);
    assert.equal(sent.body.status, 'pending');
    assert.equal(sent.body.sender_user_id, a.id);
    assert.equal(sent.body.sender.user_id, a.id);

    const pushed = await bWs.next(ofType('contact_request'));
    assert.equal(pushed.request.id, sent.body.id);

    const again = await api(srv.base, 'POST', '/api/contact-requests', { token: a.token, body: { receiver_id: b.id } });
    assert.equal(again.status, 201);
    assert.equal(again.body.id, sent.body.id, 're-sending is idempotent');

    const pendingA = await api(srv.base, 'GET', '/api/contact-requests', { token: a.token });
    const pendingB = await api(srv.base, 'GET', '/api/contact-requests', { token: b.token });
    assert.deepEqual(pendingA.body.map((r) => r.id), [sent.body.id]);
    assert.deepEqual(pendingB.body.map((r) => r.id), [sent.body.id]);

    // Only the receiver can accept.
    const byA = await api(srv.base, 'POST', `/api/contact-requests/${sent.body.id}/accept`, { token: a.token });
    assert.equal(byA.status, 404);

    const acc = await api(srv.base, 'POST', `/api/contact-requests/${sent.body.id}/accept`, { token: b.token });
    assert.equal(acc.status, 200);
    assert.equal(acc.body.status, 'accepted');
    const update = await aWs.next(ofType('contact_request_update'));
    assert.equal(update.request.status, 'accepted');
    const presence = await aWs.next(ofType('presence', (f) => f.user_id === b.id));
    assert.equal(presence.online, true, 'new contacts learn each other’s presence immediately');

    const contactsA = await api(srv.base, 'GET', '/api/contacts', { token: a.token });
    const contactsB = await api(srv.base, 'GET', '/api/contacts', { token: b.token });
    assert.deepEqual(contactsA.body.map((c) => c.contact_user_id), [b.id]);
    assert.deepEqual(contactsB.body.map((c) => c.contact_user_id), [a.id]);
    assert.equal(contactsA.body[0].contact_user.status, 'online');

    assert.deepEqual((await api(srv.base, 'GET', '/api/contact-requests', { token: a.token })).body, []);
    const dup = await api(srv.base, 'POST', '/api/contact-requests', { token: b.token, body: { receiver_id: a.id } });
    assert.equal(dup.status, 409);
    assert.equal(dup.body.error, 'already_contacts');

    // Accepting twice is a 404, not a crash.
    assert.equal((await api(srv.base, 'POST', `/api/contact-requests/${sent.body.id}/accept`, { token: b.token })).status, 404);
    await aWs.close();
    await bWs.close();
  });

  test('crossing requests: sending back to someone who asked you accepts', async () => {
    const a = await signup(srv.base, 'cross_a');
    const b = await signup(srv.base, 'cross_b');
    await api(srv.base, 'POST', '/api/contact-requests', { token: a.token, body: { receiver_id: b.id } });
    const back = await api(srv.base, 'POST', '/api/contact-requests', { token: b.token, body: { username: a.username } });
    assert.equal(back.status, 200);
    assert.equal(back.body.status, 'accepted');
    const contactsA = await api(srv.base, 'GET', '/api/contacts', { token: a.token });
    assert.deepEqual(contactsA.body.map((c) => c.contact_user_id), [b.id]);
  });

  test('reject, cancel, re-request after rejection', async () => {
    const a = await signup(srv.base, 'rej_a');
    const b = await signup(srv.base, 'rej_b');
    const sent = await api(srv.base, 'POST', '/api/contact-requests', { token: a.token, body: { receiver_id: b.id } });
    assert.equal((await api(srv.base, 'POST', `/api/contact-requests/${sent.body.id}/reject`, { token: a.token })).status, 404);
    const rej = await api(srv.base, 'POST', `/api/contact-requests/${sent.body.id}/reject`, { token: b.token });
    assert.equal(rej.body.status, 'rejected');
    assert.deepEqual((await api(srv.base, 'GET', '/api/contact-requests', { token: b.token })).body, []);
    assert.deepEqual((await api(srv.base, 'GET', '/api/contacts', { token: a.token })).body, []);

    const again = await api(srv.base, 'POST', '/api/contact-requests', { token: a.token, body: { receiver_id: b.id } });
    assert.equal(again.status, 201);
    assert.equal(again.body.status, 'pending');
    assert.equal((await api(srv.base, 'DELETE', `/api/contact-requests/${again.body.id}`, { token: b.token })).status, 404);
    assert.equal((await api(srv.base, 'DELETE', `/api/contact-requests/${again.body.id}`, { token: a.token })).status, 204);
    assert.deepEqual((await api(srv.base, 'GET', '/api/contact-requests', { token: b.token })).body, []);
  });

  test('invalid requests', async () => {
    const a = await signup(srv.base, 'inv_a');
    const self = await api(srv.base, 'POST', '/api/contact-requests', { token: a.token, body: { receiver_id: a.id } });
    assert.equal(self.status, 400);
    const ghost = await api(srv.base, 'POST', '/api/contact-requests', {
      token: a.token,
      body: { receiver_id: '00000000-0000-4000-8000-000000000000' },
    });
    assert.equal(ghost.status, 404);
    const junk = await api(srv.base, 'POST', '/api/contact-requests', { token: a.token, body: { receiver_id: "1' OR '1'='1" } });
    assert.equal(junk.status, 400);
    assert.equal((await api(srv.base, 'POST', '/api/contact-requests', { token: a.token, body: [] })).status, 400);
  });

  test('removing a contact removes it for both and notifies the other side', async () => {
    const a = await signup(srv.base, 'rm_a');
    const b = await signup(srv.base, 'rm_b');
    await makeContacts(srv.base, a, b);
    const bWs = await connectWs(srv.wsUrl, b.token);
    await bWs.next(ofType('hello'));
    assert.equal((await api(srv.base, 'DELETE', `/api/contacts/${b.id}`, { token: a.token })).status, 204);
    const removed = await bWs.next(ofType('contact_removed'));
    assert.equal(removed.user_id, a.id);
    assert.deepEqual((await api(srv.base, 'GET', '/api/contacts', { token: b.token })).body, []);
    assert.equal((await api(srv.base, 'DELETE', `/api/contacts/${b.id}`, { token: a.token })).status, 404);
    // They can become contacts again.
    await makeContacts(srv.base, b, a);
    await bWs.close();
  });

  test('nicknames are per owner', async () => {
    const a = await signup(srv.base, 'nick_a');
    const b = await signup(srv.base, 'nick_b');
    await makeContacts(srv.base, a, b);
    const r = await api(srv.base, 'PATCH', `/api/contacts/${b.id}`, { token: a.token, body: { nickname: 'Bobby' } });
    assert.equal(r.status, 200);
    assert.equal((await api(srv.base, 'GET', '/api/contacts', { token: a.token })).body[0].nickname, 'Bobby');
    assert.equal((await api(srv.base, 'GET', '/api/contacts', { token: b.token })).body[0].nickname, null);
  });
});
