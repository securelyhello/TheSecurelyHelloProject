import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { after, before, describe, test } from 'node:test';

import { isDisposableEmail, leadingZeroBits, solvePow } from '../src/spam.js';
import { GENEROUS_LIMITS, api, makeContacts, signup, startServer } from './helpers.js';

const ADMIN = 'a'.repeat(40);
const admin = { authorization: `Bearer ${ADMIN}` };

describe('spam primitives', () => {
  test('leading zero bits', () => {
    assert.equal(leadingZeroBits(Buffer.from([0x00, 0x00, 0x80])), 16);
    assert.equal(leadingZeroBits(Buffer.from([0x0f])), 4);
    assert.equal(leadingZeroBits(Buffer.from([0x00, 0x01])), 15);
    assert.equal(leadingZeroBits(Buffer.from([0xff])), 0);
  });

  test('disposable domains, including subdomains and any case', () => {
    assert.equal(isDisposableEmail('x@mailinator.com'), true);
    assert.equal(isDisposableEmail('x@Inbox.MAILINATOR.com'), true);
    assert.equal(isDisposableEmail('x@gmail.com'), false);
    assert.equal(isDisposableEmail('x@notmailinator.com'), false);
  });
});

describe('proof of work', () => {
  let srv;
  before(async () => {
    srv = await startServer({ env: { POW_BITS: '10' } });
  });
  after(() => srv.close());

  const creds = () => {
    const u = `pow_${randomUUID().slice(0, 8)}`;
    return { email: `${u}@example.test`, password: 'correct horse battery staple', username: u };
  };
  const challenge = async (purpose) =>
    (await api(srv.base, 'GET', `/api/auth/challenge?purpose=${purpose}`)).body;

  test('signup needs a solved, fresh challenge for signing up', async () => {
    const none = await api(srv.base, 'POST', '/api/auth/signup', { body: creds() });
    assert.equal(none.status, 428);
    assert.equal(none.body.error, 'pow_required');

    const c = await challenge('signup');
    assert.equal(c.bits, 10);
    const wrong = await api(srv.base, 'POST', '/api/auth/signup', {
      body: { ...creds(), pow: { challenge: c.challenge, nonce: 'not-a-solution' } },
    });
    assert.equal(wrong.body.error, 'pow_invalid');
    // A failed attempt spends the challenge.
    const nonce = solvePow('signup', c.challenge, 10);
    const reused = await api(srv.base, 'POST', '/api/auth/signup', { body: { ...creds(), pow: { challenge: c.challenge, nonce } } });
    assert.equal(reused.body.error, 'pow_invalid');

    const resetChallenge = await challenge('reset');
    const crossPurpose = await api(srv.base, 'POST', '/api/auth/signup', {
      body: { ...creds(), pow: { challenge: resetChallenge.challenge, nonce: solvePow('signup', resetChallenge.challenge, 10) } },
    });
    assert.equal(crossPurpose.body.error, 'pow_invalid', 'a reset challenge does not sign up');

    const fresh = await challenge('signup');
    const ok = await api(srv.base, 'POST', '/api/auth/signup', {
      body: { ...creds(), pow: { challenge: fresh.challenge, nonce: solvePow('signup', fresh.challenge, 10) } },
    });
    assert.equal(ok.status, 201);
  });

  test('reset e-mails need one too', async () => {
    const none = await api(srv.base, 'POST', '/api/auth/password/forgot', { body: { email: 'x@example.test' } });
    assert.equal(none.status, 428);
    const c = await challenge('reset');
    const ok = await api(srv.base, 'POST', '/api/auth/password/forgot', {
      body: { email: 'x@example.test', pow: { challenge: c.challenge, nonce: solvePow('reset', c.challenge, 10) } },
    });
    assert.equal(ok.status, 202);
  });

  test('bad purposes are refused', async () => {
    assert.equal((await api(srv.base, 'GET', '/api/auth/challenge?purpose=x')).status, 400);
  });
});

describe('accounts and requests', () => {
  let srv;
  before(async () => {
    srv = await startServer({
      env: { ADMIN_TOKEN: ADMIN },
      limitOverrides: { ...GENEROUS_LIMITS, contactRequestNew: { capacity: 3, perMs: 60_000 } },
    });
  });
  after(() => srv.close());

  const request = (from, to) =>
    api(srv.base, 'POST', '/api/contact-requests', { token: from.token, body: { receiver_id: to.id } });

  test('disposable e-mail addresses are refused', async () => {
    const res = await api(srv.base, 'POST', '/api/auth/signup', {
      body: { email: 'bot@yopmail.com', password: 'correct horse battery staple', username: `bot_${Date.now()}` },
    });
    assert.equal(res.status, 422);
    assert.equal(res.body.error, 'disposable_email');
  });

  test('a day-old account has a smaller request quota', async () => {
    const spammer = await signup(srv.base, 'newbie');
    for (let i = 0; i < 3; i++) assert.equal((await request(spammer, await signup(srv.base, `t${i}`))).status, 201);
    assert.equal((await request(spammer, await signup(srv.base, 't4'))).status, 429);

    const veteran = await signup(srv.base, 'veteran');
    await srv.pool.query("UPDATE users SET created_at = now() - interval '2 days' WHERE id = $1", [veteran.id]);
    for (let i = 0; i < 4; i++) assert.equal((await request(veteran, await signup(srv.base, `v${i}`))).status, 201);
  });

  test('requests show how old the sender account is', async () => {
    const a = await signup(srv.base, 'age_a');
    const b = await signup(srv.base, 'age_b');
    await request(a, b);
    const inbox = await api(srv.base, 'GET', '/api/contact-requests', { token: b.token });
    const r = [...(inbox.body.incoming ?? inbox.body)].find((x) => x.sender_user_id === a.id);
    assert.ok(r.sender_joined_at, JSON.stringify(inbox.body).slice(0, 300));
  });

  test('reports from three people restrict new requests, not existing chats', async () => {
    const spammer = await signup(srv.base, 'reported');
    await srv.pool.query("UPDATE users SET created_at = now() - interval '2 days' WHERE id = $1", [spammer.id]);
    const friend = await signup(srv.base, 'friend');
    await makeContacts(srv.base, spammer, friend);
    for (let i = 0; i < 3; i++) {
      const reporter = await signup(srv.base, `rep${i}`);
      await request(spammer, reporter);
      const res = await api(srv.base, 'POST', '/api/reports', {
        token: reporter.token,
        body: { user_id: spammer.id, reason: 'spam' },
      });
      assert.equal(res.status, 201);
    }
    await srv.pool.query("UPDATE users SET created_at = now() - interval '2 days' WHERE id = $1", [spammer.id]);
    const blocked = await request(spammer, await signup(srv.base, 'victim'));
    assert.equal(blocked.status, 403);
    assert.equal(blocked.body.error, 'restricted');
    const contacts = await api(srv.base, 'GET', '/api/contacts', { token: spammer.token });
    assert.ok(contacts.body.some((c) => c.contact_user_id === friend.id), 'existing contacts stay');

    const listed = await api(srv.base, 'GET', '/api/admin/restricted', { headers: admin });
    assert.ok(listed.body.some((u) => u.id === spammer.id && u.restricted_reason === 'reports'));
    await api(srv.base, 'DELETE', `/api/admin/users/${spammer.id}/restriction`, { headers: admin });
    assert.equal((await request(spammer, await signup(srv.base, 'victim2'))).status, 201);
  });

  // Audit run 1, U3-3: throwaway accounts used to be able to restrict anyone.
  test("reports and blocks from people who never dealt with the account don't count", async () => {
    const target = await signup(srv.base, 'innocent');
    await srv.pool.query("UPDATE users SET created_at = now() - interval '200 days' WHERE id = $1", [target.id]);
    for (let i = 0; i < 6; i++) {
      const sybil = await signup(srv.base, `sybil${i}`);
      await api(srv.base, 'POST', '/api/reports', { token: sybil.token, body: { user_id: target.id, reason: 'spam' } });
      await api(srv.base, 'POST', '/api/blocks', { token: sybil.token, body: { user_id: target.id } });
    }
    assert.equal((await request(target, await signup(srv.base, 'innocent_friend'))).status, 201);
  });

  test('one report is not enough', async () => {
    const x = await signup(srv.base, 'onerep');
    const r = await signup(srv.base, 'onereporter');
    await api(srv.base, 'POST', '/api/reports', { token: r.token, body: { user_id: x.id, reason: 'spam' } });
    await srv.pool.query("UPDATE users SET created_at = now() - interval '2 days' WHERE id = $1", [x.id]);
    assert.equal((await request(x, await signup(srv.base, 'fine'))).status, 201);
  });

  test('blocks from five people restrict', async () => {
    const x = await signup(srv.base, 'blocked5');
    await srv.pool.query("UPDATE users SET created_at = now() - interval '2 days' WHERE id = $1", [x.id]);
    for (let i = 0; i < 5; i++) {
      const b = await signup(srv.base, `blk${i}`);
      await request(x, b);
      await api(srv.base, 'POST', '/api/blocks', { token: b.token, body: { user_id: x.id } });
    }
    assert.equal((await request(x, await signup(srv.base, 'next'))).body.error, 'restricted');
  });

  test('most requests rejected: restricted for a day', async () => {
    const x = await signup(srv.base, 'rejected');
    await srv.pool.query("UPDATE users SET created_at = now() - interval '2 days' WHERE id = $1", [x.id]);
    for (let i = 0; i < 10; i++) {
      const t = await signup(srv.base, `rj${i}`);
      const r = await request(x, t);
      assert.equal(r.status, 201);
      await api(srv.base, 'POST', `/api/contact-requests/${r.body.id}/reject`, { token: t.token });
    }
    const res = await request(x, await signup(srv.base, 'rj_next'));
    assert.equal(res.body.error, 'restricted');
    const { rows } = await srv.pool.query('SELECT restricted_until - now() AS left FROM users WHERE id = $1', [x.id]);
    assert.ok(rows[0].left.hours <= 24 && (rows[0].left.days ?? 0) === 0);
  });
});
