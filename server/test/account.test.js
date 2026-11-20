// Account management (1.1): sign out other sessions, export your data,
// change your e-mail with a code sent to the new address.
import assert from 'node:assert/strict';
import { after, before, describe, test } from 'node:test';

import { captureMailer } from '../src/mail.js';
import { addDevice, api, connectWs, makeContacts, signup, startServer } from './helpers.js';

const DAY = 24 * 60 * 60_000;
const pendingEmail = async (srv, user) =>
  (await srv.pool.query('SELECT pending_email FROM users WHERE id = $1', [user.id])).rows[0].pending_email;
const startChange = (srv, user, email) =>
  api(srv.base, 'POST', '/api/me/email', { token: user.token, body: { email, current_password: user.password } });
const confirmChange = (srv, user, code) =>
  api(srv.base, 'POST', '/api/me/email/confirm', { token: user.token, body: { code } });

describe('account', () => {
  let srv;
  before(async () => {
    srv = await startServer();
  });
  after(() => srv.close());

  test('sign out every other session, keeping this one', async () => {
    const a = await signup(srv.base, 'acc_out');
    const laptop = await addDevice(srv.base, a);
    assert.equal((await api(srv.base, 'GET', '/api/me', { token: laptop.token })).status, 200);
    const wrong = await api(srv.base, 'POST', '/api/auth/signout-others', {
      token: a.token,
      body: { current_password: 'nope' },
    });
    assert.equal(wrong.status, 403);
    const ok = await api(srv.base, 'POST', '/api/auth/signout-others', {
      token: a.token,
      body: { current_password: a.password },
    });
    assert.equal(ok.status, 200);
    assert.equal(ok.body.signed_out, 1);
    assert.equal((await api(srv.base, 'GET', '/api/me', { token: laptop.token })).status, 401);
    assert.equal((await api(srv.base, 'GET', '/api/me', { token: a.token })).status, 200);
  });

  test('export: what the server holds about you, nothing secret', async () => {
    const a = await signup(srv.base, 'acc_exp');
    const b = await signup(srv.base, 'acc_exp_b');
    await makeContacts(srv.base, a, b);
    const r = await api(srv.base, 'GET', '/api/me/export', { token: a.token });
    assert.equal(r.status, 200);
    const d = r.body;
    assert.equal(d.account.email, a.email);
    assert.equal(d.account.username, a.username);
    assert.equal(d.devices.length, 1);
    assert.equal(d.contacts[0].username, b.username);
    assert.ok(Array.isArray(d.blocks) && Array.isArray(d.contact_requests) && Array.isArray(d.invites));
    assert.ok(d.sessions.count >= 1);
    assert.ok(d.exported_at);
    const text = JSON.stringify(d);
    assert.doesNotMatch(text, /password|token_hash|code_hash|secret/i);
  });

  test('change e-mail: password, then a code sent to the new address', async () => {
    const a = await signup(srv.base, 'acc_mail');
    const taken = await signup(srv.base, 'acc_mail_taken');
    const fresh = `new_${a.username}@example.test`;
    const noPw = await api(srv.base, 'POST', '/api/me/email', { token: a.token, body: { email: fresh } });
    assert.equal(noPw.status, 400);
    const dup = await api(srv.base, 'POST', '/api/me/email', {
      token: a.token,
      body: { email: taken.email, current_password: a.password },
    });
    assert.equal(dup.status, 409);
    const start = await api(srv.base, 'POST', '/api/me/email', {
      token: a.token,
      body: { email: fresh, current_password: a.password },
    });
    assert.equal(start.status, 202, JSON.stringify(start.body));
    const code = srv.mailer.lastCode(fresh);
    assert.match(code, /^\d{6}$/, 'the code goes to the new address');

    const bad = await api(srv.base, 'POST', '/api/me/email/confirm', { token: a.token, body: { code: '000000' } });
    assert.equal(bad.status, 400);
    const ok = await api(srv.base, 'POST', '/api/me/email/confirm', { token: a.token, body: { code } });
    assert.equal(ok.status, 200, JSON.stringify(ok.body));
    assert.equal(ok.body.email, fresh);
    assert.equal(ok.body.email_verified, true);
    // Signing in uses the new address now.
    const signin = await api(srv.base, 'POST', '/api/auth/signin', { body: { email: fresh, password: a.password } });
    assert.equal(signin.status, 200);
  });
});

describe('e-mail change hardening', () => {
  let srv;
  // A mailer that can't deliver to addresses containing "undeliverable".
  const mailer = captureMailer();
  const send = mailer.send.bind(mailer);
  mailer.send = async (msg) => {
    if (msg.to.includes('undeliverable')) throw new Error('smtp said no');
    return send(msg);
  };
  before(async () => {
    srv = await startServer({
      mailer,
      // Small enough that a test can use it up.
      limitOverrides: { emailDaily: { capacity: 50, perMs: DAY, sliding: true } },
    });
  });
  after(() => srv.close());

  test('pending_email is only set once the code is out', async () => {
    const a = await signup(srv.base, 'chg_fail');
    const r = await startChange(srv, a, `undeliverable_${a.username}@example.test`);
    assert.notEqual(r.status, 202);
    assert.equal(await pendingEmail(srv, a), null);
  });

  test('a code only confirms the address it was sent to', async () => {
    const a = await signup(srv.base, 'chg_bind');
    const first = `first_${a.username}@example.test`;
    assert.equal((await startChange(srv, a, first)).status, 202);
    const code = srv.mailer.lastCode(first);
    // The pending address moves on without a new code (any path at all).
    const other = `other_${a.username}@example.test`;
    await srv.pool.query('UPDATE users SET pending_email = $2 WHERE id = $1', [a.id, other]);
    const r = await confirmChange(srv, a, code);
    assert.equal(r.status, 400);
    const me = await api(srv.base, 'GET', '/api/me', { token: a.token });
    assert.equal(me.body.email, a.email, 'unchanged');
  });

  test('the old address hears about the change; other sessions are signed out', async () => {
    const a = await signup(srv.base, 'chg_note');
    const laptop = await addDevice(srv.base, a);
    const laptopWs = await connectWs(srv.wsUrl, laptop.token);
    const closed = new Promise((resolve) => laptopWs.ws.once('close', (code) => resolve(code)));
    const fresh = `fresh_${a.username}@example.test`;
    assert.equal((await startChange(srv, a, fresh)).status, 202);
    const before = srv.mailer.sent.filter((m) => m.to === a.email).length;
    const ok = await confirmChange(srv, a, srv.mailer.lastCode(fresh));
    assert.equal(ok.status, 200, JSON.stringify(ok.body));
    assert.equal(ok.body.email, fresh);

    const notices = srv.mailer.sent.filter((m) => m.to === a.email).slice(before);
    assert.equal(notices.length, 1, 'one notice to the old address');
    assert.match(notices[0].subject, /e-mail/i);
    assert.doesNotMatch(notices[0].text, /\b\d{6}\b/, 'a notice, not a code');

    assert.equal((await api(srv.base, 'GET', '/api/me', { token: laptop.token })).status, 401);
    assert.equal((await api(srv.base, 'GET', '/api/me', { token: a.token })).status, 200, 'this session stays');
    assert.equal(typeof (await closed), 'number', 'the other socket is closed');
  });

  test('with the daily e-mail cap used up the change still completes, without the notice', async () => {
    const a = await signup(srv.base, 'chg_cap');
    const fresh = `capped_${a.username}@example.test`;
    assert.equal((await startChange(srv, a, fresh)).status, 202);
    const code = srv.mailer.lastCode(fresh);
    while (await srv.store.slidingHit('emailDaily', 'global', 50, DAY));
    const before = srv.mailer.sent.length;
    const ok = await confirmChange(srv, a, code);
    assert.equal(ok.status, 200, JSON.stringify(ok.body));
    assert.equal(ok.body.email, fresh);
    assert.equal(srv.mailer.sent.length, before, 'nothing sent past the cap');
  });
});
