import assert from 'node:assert/strict';
import { after, before, describe, test } from 'node:test';

import { api, connectWs, mailCount, nextCode, signup, startServer } from './helpers.js';

describe('e-mail verification (required)', () => {
  let srv;
  before(async () => {
    srv = await startServer({ env: { EMAIL_VERIFICATION: 'required' } });
  });
  after(() => srv.close());

  test('sign up e-mails a code; the profile says unverified', async () => {
    const a = await signup(srv.base, 'ver');
    assert.equal(a.user.email_verified, false);
    assert.equal(a.user.email_verification_required, true);
    assert.match(srv.mailer.lastCode(a.email), /^\d{6}$/);
    const config = await api(srv.base, 'GET', '/api/config');
    assert.deepEqual(config.body, { email_verification: 'required', password_reset: true, push: false });
  });

  test('unverified accounts cannot send requests and are hidden from search', async () => {
    const a = await signup(srv.base, 'unv');
    const b = await signup(srv.base, 'other');
    const req = await api(srv.base, 'POST', '/api/contact-requests', { token: a.token, body: { receiver_id: b.id } });
    assert.equal(req.status, 403);
    assert.equal(req.body.error, 'email_unverified');

    // b verifies and searches for a: not found until a verifies.
    await api(srv.base, 'POST', '/api/auth/email/verify', {
      token: b.token,
      body: { code: srv.mailer.lastCode(b.email) },
    });
    let found = await api(srv.base, 'GET', `/api/users/search?q=${a.username}`, { token: b.token });
    assert.equal(found.body.length, 0);

    const ok = await api(srv.base, 'POST', '/api/auth/email/verify', {
      token: a.token,
      body: { code: srv.mailer.lastCode(a.email) },
    });
    assert.equal(ok.status, 200);
    assert.equal(ok.body.email_verified, true);
    found = await api(srv.base, 'GET', `/api/users/search?q=${a.username}`, { token: b.token });
    assert.equal(found.body.length, 1);
    const req2 = await api(srv.base, 'POST', '/api/contact-requests', { token: a.token, body: { receiver_id: b.id } });
    assert.equal(req2.status, 201);
  });

  test('wrong codes count against a small budget, and a code works only once', async () => {
    const a = await signup(srv.base, 'brute');
    const code = srv.mailer.lastCode(a.email);
    const wrong = code === '000000' ? '111111' : '000000';
    for (let i = 0; i < 4; i++) {
      const res = await api(srv.base, 'POST', '/api/auth/email/verify', { token: a.token, body: { code: wrong } });
      assert.equal(res.status, 400);
      assert.equal(res.body.error, 'invalid_code');
    }
    // 5th guess (the right one) still within budget
    const ok = await api(srv.base, 'POST', '/api/auth/email/verify', { token: a.token, body: { code } });
    assert.equal(ok.status, 200);
    const again = await api(srv.base, 'POST', '/api/auth/email/verify', { token: a.token, body: { code } });
    assert.equal(again.status, 400);

    const b = await signup(srv.base, 'brute2');
    const codeB = srv.mailer.lastCode(b.email);
    const wrongB = codeB === '000000' ? '111111' : '000000';
    for (let i = 0; i < 5; i++) {
      await api(srv.base, 'POST', '/api/auth/email/verify', { token: b.token, body: { code: wrongB } });
    }
    const late = await api(srv.base, 'POST', '/api/auth/email/verify', { token: b.token, body: { code: codeB } });
    assert.equal(late.status, 400, 'the right code is useless once the budget is spent');

    // Resend issues a fresh code with a fresh budget.
    const resend = await api(srv.base, 'POST', '/api/auth/email/send-verification', { token: b.token });
    assert.equal(resend.status, 202);
    const fresh = await api(srv.base, 'POST', '/api/auth/email/verify', {
      token: b.token,
      body: { code: srv.mailer.lastCode(b.email) },
    });
    assert.equal(fresh.status, 200);
    const already = await api(srv.base, 'POST', '/api/auth/email/send-verification', { token: b.token });
    assert.equal(already.status, 409);
  });

  test('codes are stored hashed and expire', async () => {
    const a = await signup(srv.base, 'hashed');
    const code = srv.mailer.lastCode(a.email);
    const { rows } = await srv.pool.query('SELECT code_hash FROM email_codes WHERE user_id = $1', [a.id]);
    assert.equal(rows[0].code_hash.length, 32);
    assert.equal(rows[0].code_hash.toString('utf8').includes(code), false);
    await srv.pool.query("UPDATE email_codes SET expires_at = now() - interval '1 second' WHERE user_id = $1", [a.id]);
    const res = await api(srv.base, 'POST', '/api/auth/email/verify', { token: a.token, body: { code } });
    assert.equal(res.status, 400);
    const swept = await srv.app.sweep();
    assert.ok(swept.codes >= 1);
  });
});

describe('password reset', () => {
  let srv;
  before(async () => {
    srv = await startServer();
  });
  after(() => srv.close());

  test('forgot answers the same for unknown addresses', async () => {
    const res = await api(srv.base, 'POST', '/api/auth/password/forgot', {
      body: { email: 'nobody@example.test' },
    });
    assert.equal(res.status, 202);
    assert.equal(srv.mailer.lastCode('nobody@example.test'), null);
  });

  test('reset with the e-mailed code: new password works, old sessions are revoked', async () => {
    const a = await signup(srv.base, 'forgot');
    const ws = await connectWs(srv.wsUrl, a.token);
    await ws.next((f) => f.type === 'hello');
    const closed = new Promise((resolve) => ws.ws.once('close', (code) => resolve(code)));

    const before = mailCount(srv, a.email);
    const forgot = await api(srv.base, 'POST', '/api/auth/password/forgot', { body: { email: a.email.toUpperCase() } });
    assert.equal(forgot.status, 202);
    const code = await nextCode(srv, a.email, before);
    assert.match(code, /^\d{6}$/);

    const bad = await api(srv.base, 'POST', '/api/auth/password/reset', {
      body: { email: a.email, code: code === '999999' ? '000000' : '999999', new_password: 'a brand new password' },
    });
    assert.equal(bad.status, 400);

    const weak = await api(srv.base, 'POST', '/api/auth/password/reset', {
      body: { email: a.email, code, new_password: 'short' },
    });
    assert.equal(weak.status, 400);
    assert.equal(weak.body.error, 'weak_password');

    const ok = await api(srv.base, 'POST', '/api/auth/password/reset', {
      body: { email: a.email, code, new_password: 'a brand new password' },
    });
    assert.equal(ok.status, 200);
    assert.match(ok.body.token, /^[A-Za-z0-9_-]{43}$/);
    assert.equal(ok.body.user.email_verified, true, 'resetting proves the inbox');
    assert.equal(await closed, 4001);

    const oldSession = await api(srv.base, 'GET', '/api/me', { token: a.token });
    assert.equal(oldSession.status, 401);
    const newSession = await api(srv.base, 'GET', '/api/me', { token: ok.body.token });
    assert.equal(newSession.status, 200);

    const oldPw = await api(srv.base, 'POST', '/api/auth/signin', { body: { email: a.email, password: a.password } });
    assert.equal(oldPw.status, 401);
    const newPw = await api(srv.base, 'POST', '/api/auth/signin', {
      body: { email: a.email, password: 'a brand new password' },
    });
    assert.equal(newPw.status, 200);

    const reuse = await api(srv.base, 'POST', '/api/auth/password/reset', {
      body: { email: a.email, code, new_password: 'yet another password' },
    });
    assert.equal(reuse.status, 400, 'a code is single-use');
  });

});

describe('e-mail disabled', () => {
  let off;
  before(async () => {
    off = await startServer({
      env: { EMAIL_VERIFICATION: 'required' },
      mailer: { transport: 'none', enabled: false, send: async () => {} },
    });
  });
  after(() => off.close());

  test('verification falls back to optional and reset is unavailable', async () => {
    const config = await api(off.base, 'GET', '/api/config');
    assert.deepEqual(config.body, { email_verification: 'optional', password_reset: false, push: false });
    const res = await api(off.base, 'POST', '/api/auth/password/forgot', { body: { email: 'x@example.test' } });
    assert.equal(res.status, 503);
    assert.equal(res.body.error, 'email_unavailable');
    const a = await signup(off.base, 'nomail');
    assert.equal(a.user.email_verified, false);
    assert.equal(a.user.email_verification_required, false);
  });
});
