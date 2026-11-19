// Account management (1.1): sign out other sessions, export your data,
// change your e-mail with a code sent to the new address.
import assert from 'node:assert/strict';
import { after, before, describe, test } from 'node:test';

import { addDevice, api, makeContacts, signup, startServer } from './helpers.js';

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
