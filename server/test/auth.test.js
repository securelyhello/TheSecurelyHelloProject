import assert from 'node:assert/strict';
import { after, before, describe, test } from 'node:test';

import { api, makeContacts, relaySend, signup, startServer } from './helpers.js';

let srv;
before(async () => {
  srv = await startServer({ limitOverrides: { authAccount: { capacity: 4, perMs: 60_000 } } });
});
after(() => srv.close());

describe('auth', () => {
  test('sign up returns a session token and the profile, never the password hash', async () => {
    const res = await api(srv.base, 'POST', '/api/auth/signup', {
      body: {
        email: 'Alice@Example.test',
        password: 'a long enough password',
        username: 'Alice_1',
        display_name: 'Alice',
      },
    });
    assert.equal(res.status, 201);
    assert.match(res.body.token, /^[A-Za-z0-9_-]{43}$/);
    assert.equal(res.body.user.username, 'alice_1', 'usernames are normalised to lower case');
    assert.equal(res.body.user.email, 'Alice@Example.test');
    assert.equal(JSON.stringify(res.body).includes('scrypt'), false);

    const { rows } = await srv.pool.query('SELECT password_hash FROM users WHERE username = $1', ['alice_1']);
    assert.match(rows[0].password_hash, /^scrypt\$32768\$8\$1\$/);
    const sessions = await srv.pool.query('SELECT token_hash FROM sessions');
    assert.equal(
      sessions.rows.some((r) => r.token_hash.toString('utf8').includes(res.body.token)),
      false,
      'only the token hash is stored',
    );
  });

  test('duplicate e-mail (case-insensitive) and username are rejected', async () => {
    const a = await signup(srv.base, 'dup');
    const sameEmail = await api(srv.base, 'POST', '/api/auth/signup', {
      body: { ...a, email: a.email.toUpperCase(), username: 'someone_else' },
    });
    assert.equal(sameEmail.status, 409);
    assert.equal(sameEmail.body.error, 'email_taken');
    const sameUser = await api(srv.base, 'POST', '/api/auth/signup', {
      body: { ...a, email: 'other@example.test' },
    });
    assert.equal(sameUser.status, 409);
    assert.equal(sameUser.body.error, 'username_taken');
  });

  test('input validation on sign up', async () => {
    const good = {
      email: 'v@example.test',
      password: 'a long enough password',
      username: 'valid_name',
      display_name: 'V',
    };
    const cases = [
      [{ password: 'short' }, 'weak_password'],
      [{ password: 'x'.repeat(300) }, 'weak_password'],
      [{ username: 'no spaces' }, 'invalid_username'],
      [{ username: 'ab' }, 'invalid_username'],
      [{ username: "x'; DROP TABLE users;--" }, 'invalid_username'],
      [{ email: 'not-an-email' }, 'invalid_email'],
      [{ display_name: 'x'.repeat(65) }, 'invalid_input'],
    ];
    for (const [patch, code] of cases) {
      const res = await api(srv.base, 'POST', '/api/auth/signup', { body: { ...good, ...patch } });
      assert.equal(res.status, 400, JSON.stringify(patch));
      assert.equal(res.body.error, code, JSON.stringify(patch));
    }
    const notJson = await api(srv.base, 'POST', '/api/auth/signup', {
      body: 'email=x',
      headers: { 'Content-Type': 'text/plain' },
    });
    assert.equal(notJson.status, 415);
    const huge = await api(srv.base, 'POST', '/api/auth/signup', { body: { ...good, pad: 'x'.repeat(300_000) } });
    assert.equal(huge.status, 413);
  });

  test('sign in, wrong password, unknown account', async () => {
    const a = await signup(srv.base, 'signin');
    const ok = await api(srv.base, 'POST', '/api/auth/signin', {
      body: { email: a.email.toUpperCase(), password: a.password },
    });
    assert.equal(ok.status, 200);
    assert.equal(ok.body.user.user_id, a.id);
    assert.notEqual(ok.body.token, a.token, 'each sign-in gets its own session');

    const wrong = await api(srv.base, 'POST', '/api/auth/signin', { body: { email: a.email, password: 'nope nope nope' } });
    assert.equal(wrong.status, 401);
    const unknown = await api(srv.base, 'POST', '/api/auth/signin', {
      body: { email: 'ghost@example.test', password: 'whatever123' },
    });
    assert.equal(unknown.status, 401);
    assert.equal(unknown.body.error, wrong.body.error, 'no account enumeration via sign-in');
  });

  test('sign-in is rate limited per account', async () => {
    const a = await signup(srv.base, 'ratelimit');
    const codes = [];
    for (let i = 0; i < 6; i++) {
      const r = await api(srv.base, 'POST', '/api/auth/signin', { body: { email: a.email, password: 'wrong password' } });
      codes.push(r.status);
    }
    assert.deepEqual(codes.slice(0, 4), [401, 401, 401, 401]);
    assert.deepEqual(codes.slice(4), [429, 429]);
  });

  test('protected routes need a valid bearer token', async () => {
    assert.equal((await api(srv.base, 'GET', '/api/me')).status, 401);
    assert.equal((await api(srv.base, 'GET', '/api/me', { token: 'x'.repeat(43) })).status, 401);
    assert.equal(
      (await api(srv.base, 'GET', '/api/me', { headers: { Authorization: 'Basic abc' } })).status,
      401,
    );
  });

  test('sign out revokes only that session', async () => {
    const a = await signup(srv.base, 'signout');
    const second = await api(srv.base, 'POST', '/api/auth/signin', { body: { email: a.email, password: a.password } });
    assert.equal((await api(srv.base, 'POST', '/api/auth/signout', { token: a.token })).status, 204);
    assert.equal((await api(srv.base, 'GET', '/api/me', { token: a.token })).status, 401);
    assert.equal((await api(srv.base, 'GET', '/api/me', { token: second.body.token })).status, 200);
  });

  test('expired sessions are rejected and swept', async () => {
    const a = await signup(srv.base, 'expired');
    await srv.pool.query(`UPDATE sessions SET expires_at = now() - interval '1 second' WHERE user_id = $1`, [a.id]);
    assert.equal((await api(srv.base, 'GET', '/api/me', { token: a.token })).status, 401);
    const swept = await srv.app.sweep();
    assert.ok(swept.sessions >= 1);
  });

  test('change password checks the current one and revokes other sessions', async () => {
    const a = await signup(srv.base, 'chpw');
    const other = await api(srv.base, 'POST', '/api/auth/signin', { body: { email: a.email, password: a.password } });
    const wrong = await api(srv.base, 'POST', '/api/auth/change-password', {
      token: a.token,
      body: { current_password: 'not it at all', new_password: 'brand new password' },
    });
    assert.equal(wrong.status, 403);
    const weak = await api(srv.base, 'POST', '/api/auth/change-password', {
      token: a.token,
      body: { current_password: a.password, new_password: 'short' },
    });
    assert.equal(weak.status, 400);
    const ok = await api(srv.base, 'POST', '/api/auth/change-password', {
      token: a.token,
      body: { current_password: a.password, new_password: 'brand new password' },
    });
    assert.equal(ok.status, 204);
    assert.equal((await api(srv.base, 'GET', '/api/me', { token: a.token })).status, 200, 'current session kept');
    assert.equal((await api(srv.base, 'GET', '/api/me', { token: other.body.token })).status, 401, 'others revoked');
    const oldPw = await api(srv.base, 'POST', '/api/auth/signin', { body: { email: a.email, password: a.password } });
    assert.equal(oldPw.status, 401);
    const newPw = await api(srv.base, 'POST', '/api/auth/signin', {
      body: { email: a.email, password: 'brand new password' },
    });
    assert.equal(newPw.status, 200);
  });

  test('username availability is public', async () => {
    const a = await signup(srv.base, 'avail');
    const taken = await api(srv.base, 'GET', `/api/usernames/${a.username.toUpperCase()}/available`);
    assert.deepEqual(taken.body, { username: a.username, available: false });
    const free = await api(srv.base, 'GET', '/api/usernames/nobody_has_this/available');
    assert.equal(free.body.available, true);
    assert.equal((await api(srv.base, 'GET', '/api/usernames/a%20b/available')).status, 400);
  });

  test('delete account cascades to sessions, contacts, requests and relay rows', async () => {
    const a = await signup(srv.base, 'del_a');
    const b = await signup(srv.base, 'del_b');
    const c = await signup(srv.base, 'del_c');
    await makeContacts(srv.base, a, b);
    await api(srv.base, 'POST', '/api/contact-requests', { token: a.token, body: { receiver_id: c.id } });
    assert.equal((await relaySend(srv.base, a, b)).status, 201);
    assert.equal((await relaySend(srv.base, b, a)).status, 201);

    assert.equal((await api(srv.base, 'DELETE', '/api/me', { token: a.token, body: { current_password: a.password } })).status, 204);
    assert.equal((await api(srv.base, 'GET', '/api/me', { token: a.token })).status, 401);
    for (const [table, col] of [
      ['sessions', 'user_id'],
      ['contacts', 'owner_id'],
      ['contacts', 'contact_id'],
      ['contact_requests', 'sender_id'],
    ]) {
      const { rows } = await srv.pool.query(`SELECT count(*)::int AS n FROM ${table} WHERE ${col} = $1`, [a.id]);
      assert.equal(rows[0].n, 0, `${table}.${col}`);
    }
    assert.deepEqual((await api(srv.base, 'GET', '/api/relay', { token: b.token })).body, [], 'queued from the deleted user');
    assert.deepEqual(await srv.redis.keys('sh:relay:m:*'), [], 'no envelopes left in Redis');
    const contactsOfB = await api(srv.base, 'GET', '/api/contacts', { token: b.token });
    assert.deepEqual(contactsOfB.body, []);
    const signin = await api(srv.base, 'POST', '/api/auth/signin', { body: { email: a.email, password: a.password } });
    assert.equal(signin.status, 401);
  });
});
