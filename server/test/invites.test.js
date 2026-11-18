import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { after, before, describe, test } from 'node:test';

import { api, connectWs, ofType, signup, startServer, verifyEmail } from './helpers.js';

const hashOf = (email) =>
  createHash('sha256').update(`securelyhello-email|${email.toLowerCase()}`).digest('base64');

let srv;
before(async () => {
  srv = await startServer({ env: { INVITE_BASE_URL: 'https://hello.example/i/' } });
});
after(() => srv.close());

describe('invites', () => {
  test('opening and accepting an invite makes two people contacts', async () => {
    const a = await signup(srv.base, 'inviter');
    const b = await signup(srv.base, 'invitee');
    const made = await api(srv.base, 'POST', '/api/invites', { token: a.token });
    assert.equal(made.status, 201);
    assert.equal(made.body.url, `https://hello.example/i/${made.body.token}`);
    const { rows } = await srv.pool.query('SELECT token_hash FROM invites');
    assert.ok(rows.every((r) => !r.token_hash.toString().includes(made.body.token)), 'stored hashed');

    const preview = await api(srv.base, 'GET', `/api/invites/${made.body.token}`, { token: b.token });
    assert.equal(preview.body.inviter.username, a.username);
    assert.equal(preview.body.already_contacts, false);

    const aWs = await connectWs(srv.wsUrl, a.token);
    const accepted = await api(srv.base, 'POST', `/api/invites/${made.body.token}/accept`, { token: b.token });
    assert.equal(accepted.status, 200);
    assert.equal(accepted.body.contact_user_id, a.id);
    const event = await aWs.next(ofType('contact_added'));
    assert.equal(event.user_id, b.id);
    await aWs.close();

    const contacts = await api(srv.base, 'GET', '/api/contacts', { token: a.token });
    assert.ok(contacts.body.some((c) => c.contact_user_id === b.id));
    const again = await api(srv.base, 'POST', `/api/invites/${made.body.token}/accept`, { token: b.token });
    assert.equal(again.status, 200, 'accepting twice is harmless');
    const { rows: uses } = await srv.pool.query('SELECT uses FROM invites WHERE inviter_id = $1', [a.id]);
    assert.equal(uses[0].uses, 1, 'only counted once');
  });

  test('own, junk, revoked and blocked invites', async () => {
    const a = await signup(srv.base, 'inv_own');
    const b = await signup(srv.base, 'inv_other');
    const { body } = await api(srv.base, 'POST', '/api/invites', { token: a.token });
    assert.equal((await api(srv.base, 'POST', `/api/invites/${body.token}/accept`, { token: a.token })).status, 400);
    assert.equal((await api(srv.base, 'GET', '/api/invites/not-a-token', { token: b.token })).status, 404);

    await api(srv.base, 'POST', '/api/blocks', { token: a.token, body: { user_id: b.id } });
    assert.equal((await api(srv.base, 'POST', `/api/invites/${body.token}/accept`, { token: b.token })).status, 404);
    await api(srv.base, 'DELETE', `/api/blocks/${b.id}`, { token: a.token });

    const revoked = await api(srv.base, 'DELETE', '/api/invites', { token: a.token });
    assert.equal(revoked.body.revoked, 1);
    assert.equal((await api(srv.base, 'GET', `/api/invites/${body.token}`, { token: b.token })).status, 404);
  });

  test('expired and used-up invites stop working', async () => {
    const a = await signup(srv.base, 'inv_exp');
    const b = await signup(srv.base, 'inv_late');
    const { body } = await api(srv.base, 'POST', '/api/invites', { token: a.token });
    await srv.pool.query("UPDATE invites SET expires_at = now() - interval '1 second' WHERE inviter_id = $1", [a.id]);
    assert.equal((await api(srv.base, 'POST', `/api/invites/${body.token}/accept`, { token: b.token })).status, 404);
    const second = await api(srv.base, 'POST', '/api/invites', { token: a.token });
    await srv.pool.query('UPDATE invites SET uses = max_uses WHERE inviter_id = $1', [a.id]);
    assert.equal((await api(srv.base, 'POST', `/api/invites/${second.body.token}/accept`, { token: b.token })).status, 404);
  });
});

describe('discovery', () => {
  test('only opted-in people match, and never by default', async () => {
    const seeker = await signup(srv.base, 'seeker_d');
    const shy = await signup(srv.base, 'shy');
    const open = await signup(srv.base, 'open');
    assert.equal((await api(srv.base, 'GET', '/api/me/discovery', { token: open.token })).body.email_discoverable, false);
    // Unverified addresses can't be made findable (audit run 1, U3-1).
    const early = await api(srv.base, 'PUT', '/api/me/discovery', { token: open.token, body: { email_discoverable: true } });
    assert.equal(early.status, 403);
    await verifyEmail(srv, open);
    await api(srv.base, 'PUT', '/api/me/discovery', { token: open.token, body: { email_discoverable: true } });

    const res = await api(srv.base, 'POST', '/api/discovery/match', {
      token: seeker.token,
      body: { hashes: [hashOf(shy.email), hashOf(open.email.toUpperCase()), hashOf('nobody@example.test')] },
    });
    assert.equal(res.status, 200);
    assert.deepEqual(res.body.map((m) => m.user.user_id), [open.id]);
    assert.equal(res.body[0].hash, hashOf(open.email));
    assert.equal(res.body[0].user.email, undefined, 'addresses are never returned');
  });

  test('blocked people and bad input', async () => {
    const seeker = await signup(srv.base, 'seeker_b');
    const blocker = await signup(srv.base, 'blocker_d');
    await verifyEmail(srv, blocker);
    await api(srv.base, 'PUT', '/api/me/discovery', { token: blocker.token, body: { email_discoverable: true } });
    await api(srv.base, 'POST', '/api/blocks', { token: blocker.token, body: { user_id: seeker.id } });
    const res = await api(srv.base, 'POST', '/api/discovery/match', {
      token: seeker.token,
      body: { hashes: [hashOf(blocker.email)] },
    });
    assert.deepEqual(res.body, []);
    const bad = await api(srv.base, 'POST', '/api/discovery/match', { token: seeker.token, body: { hashes: ['abc'] } });
    assert.equal(bad.status, 400);
    const many = await api(srv.base, 'POST', '/api/discovery/match', {
      token: seeker.token,
      body: { hashes: Array(501).fill(hashOf('x@example.test')) },
    });
    assert.equal(many.status, 400);
  });
});
