import assert from 'node:assert/strict';
import { after, before, describe, test } from 'node:test';

import { base32Decode, base32Encode, createTwoFactor, hotp, matchStep, stepAt } from '../src/twofactor.js';
import { addDevice, api, mailCount, nextCode, registerDevice, signup, startServer } from './helpers.js';

describe('TOTP primitives', () => {
  test('RFC 6238 SHA-1 vectors (last six digits)', () => {
    const secret = Buffer.from('12345678901234567890');
    assert.equal(hotp(secret, stepAt(59_000)), '287082');
    assert.equal(hotp(secret, stepAt(1_111_111_109_000)), '081804');
    assert.equal(hotp(secret, stepAt(2_000_000_000_000)), '279037');
  });

  test('base32 round-trips and accepts spaces and lower case', () => {
    const raw = Buffer.from('any secret bytes!');
    const b32 = base32Encode(raw);
    assert.deepEqual(base32Decode(b32.toLowerCase().replace(/(.{4})/g, '$1 ')), raw);
  });

  test('accepts one step of clock drift, not two', () => {
    const secret = Buffer.from('12345678901234567890');
    const now = 1_700_000_000_000;
    const step = stepAt(now);
    assert.equal(matchStep(secret, hotp(secret, step - 1), now), step - 1);
    assert.equal(matchStep(secret, hotp(secret, step + 1), now), step + 1);
    assert.equal(matchStep(secret, hotp(secret, step + 2), now), null);
    assert.equal(matchStep(secret, '12345', now), null);
  });
});

test('secrets are sealed with AES-GCM when a key is set', () => {
  const sealed = createTwoFactor({ pool: null, limits: null, config: { totpKey: 'operator key, at least 32 characters long' } }).box;
  const secret = Buffer.from('12345678901234567890');
  const stored = sealed.seal(secret);
  assert.match(stored, /^g:/);
  assert.ok(!Buffer.from(stored.slice(2), 'base64').includes(secret));
  assert.deepEqual(sealed.open(stored), secret);
  const otherKey = createTwoFactor({ pool: null, limits: null, config: { totpKey: 'another key, also 32 characters or more' } }).box;
  assert.throws(() => otherKey.open(stored));
  const plain = createTwoFactor({ pool: null, limits: null, config: {} }).box;
  assert.throws(() => createTwoFactor({ pool: null, limits: null, config: { totpKey: 'short' } }), /32 characters/);
  assert.equal(sealed.needsSealing(plain.seal(secret)), true, 'old plaintext rows get re-sealed on use');
  assert.deepEqual(sealed.open(plain.seal(secret)), secret, 'old unsealed secrets still readable');
});

describe('two-step verification', () => {
  let srv;
  before(async () => {
    srv = await startServer();
  });
  after(() => srv.close());

  const signin = (u, otp) =>
    api(srv.base, 'POST', '/api/auth/signin', { body: { email: u.email, password: u.password, otp } });

  async function enable(u) {
    const setup = await api(srv.base, 'POST', '/api/me/2fa/setup', { token: u.token, body: { password: u.password } });
    assert.equal(setup.status, 200);
    assert.match(setup.body.uri, /^otpauth:\/\/totp\/Securely%20Hello/);
    const secret = base32Decode(setup.body.secret);
    const res = await api(srv.base, 'POST', '/api/me/2fa/enable', {
      token: u.token,
      body: { code: hotp(secret, stepAt()) },
    });
    assert.equal(res.status, 200);
    return { secret, recovery: res.body.recovery_codes };
  }

  test('setup needs the password and a working code', async () => {
    const a = await signup(srv.base, 'tf_setup');
    const wrongPw = await api(srv.base, 'POST', '/api/me/2fa/setup', { token: a.token, body: { password: 'nope' } });
    assert.equal(wrongPw.status, 403);
    const early = await api(srv.base, 'POST', '/api/me/2fa/enable', { token: a.token, body: { code: '123456' } });
    assert.equal(early.status, 409, 'nothing to confirm yet');

    const setup = await api(srv.base, 'POST', '/api/me/2fa/setup', { token: a.token, body: { password: a.password } });
    const secret = base32Decode(setup.body.secret);
    const wrong = hotp(secret, stepAt() + 5);
    const bad = await api(srv.base, 'POST', '/api/me/2fa/enable', { token: a.token, body: { code: wrong } });
    assert.equal(bad.status, 400);
    const status = await api(srv.base, 'GET', '/api/me/2fa', { token: a.token });
    assert.deepEqual(status.body, { enabled: false, recovery_codes_left: 0 });
    const { rows } = await srv.pool.query('SELECT totp_pending_secret FROM users WHERE id = $1', [a.id]);
    assert.ok(!rows[0].totp_pending_secret.includes(setup.body.secret), 'not stored as given');
  });

  test('sign-in asks for a code, refuses reuse, and takes recovery codes once', async () => {
    const a = await signup(srv.base, 'tf_login');
    const { secret, recovery } = await enable(a);
    assert.equal(recovery.length, 10);
    assert.equal((await api(srv.base, 'GET', '/api/me/2fa', { token: a.token })).body.recovery_codes_left, 10);

    const missing = await signin(a);
    assert.equal(missing.status, 401);
    assert.equal(missing.body.error, 'otp_required');
    assert.equal((await signin(a, '000000')).body.error, 'invalid_otp');

    const wrongPw = await api(srv.base, 'POST', '/api/auth/signin', {
      body: { email: a.email, password: 'wrong password!', otp: '000000' },
    });
    assert.equal(wrongPw.body.error, 'invalid_credentials', 'password checked before the code');

    // The code used to enable is spent; the next step's code works once.
    assert.equal((await signin(a, hotp(secret, stepAt()))).body.error, 'invalid_otp');
    const next = hotp(secret, stepAt() + 1);
    assert.equal((await signin(a, next)).status, 200);
    assert.equal((await signin(a, next)).body.error, 'invalid_otp', 'replay refused');

    assert.equal((await signin(a, recovery[0].toUpperCase())).status, 200, 'recovery code, any case');
    assert.equal((await signin(a, recovery[0])).body.error, 'invalid_otp', 'single use');
    assert.equal((await api(srv.base, 'GET', '/api/me/2fa', { token: a.token })).body.recovery_codes_left, 9);
  });

  test('password reset by e-mail also needs the second factor', async () => {
    const a = await signup(srv.base, 'tf_reset');
    const { recovery } = await enable(a);
    const before = mailCount(srv, a.email);
    await api(srv.base, 'POST', '/api/auth/password/forgot', { body: { email: a.email } });
    const code = await nextCode(srv, a.email, before);
    const body = { email: a.email, code, new_password: 'a brand new password' };

    const noOtp = await api(srv.base, 'POST', '/api/auth/password/reset', { body });
    assert.equal(noOtp.body.error, 'otp_required');
    const badOtp = await api(srv.base, 'POST', '/api/auth/password/reset', { body: { ...body, otp: '000000' } });
    assert.equal(badOtp.body.error, 'invalid_otp');
    // The e-mailed code was kept for the retry.
    const ok = await api(srv.base, 'POST', '/api/auth/password/reset', { body: { ...body, otp: recovery[1] } });
    assert.equal(ok.status, 200);
    const again = await api(srv.base, 'POST', '/api/auth/password/reset', { body: { ...body, otp: recovery[2] } });
    assert.equal(again.body.error, 'invalid_code', 'the e-mailed code is spent');
  });

  test('a wrong reset code says invalid_code whether or not 2FA is on', async () => {
    const a = await signup(srv.base, 'tf_enum');
    await enable(a);
    const res = await api(srv.base, 'POST', '/api/auth/password/reset', {
      body: { email: a.email, code: '123456', new_password: 'a brand new password' },
    });
    assert.equal(res.body.error, 'invalid_code');
  });

  test('device recovery by e-mail needs the second factor', async () => {
    const a = await signup(srv.base, 'tf_device');
    const { recovery } = await enable(a);
    const fresh = await addDevice(srv.base, a, { approve: false }).catch(() => null);
    assert.equal(fresh, null, 'signing in for the new device needs the code too');

    const res = await signin(a, recovery[0]);
    assert.equal(res.status, 200);
    const token = res.body.token;
    await registerDevice(srv.base, token);
    await api(srv.base, 'POST', '/api/devices/current/recover', { token });
    const code = srv.mailer.lastCode(a.email);
    const noOtp = await api(srv.base, 'POST', '/api/devices/current/recover/confirm', { token, body: { code } });
    assert.equal(noOtp.body.error, 'otp_required');
    const ok = await api(srv.base, 'POST', '/api/devices/current/recover/confirm', {
      token,
      body: { code, otp: recovery[1] },
    });
    assert.equal(ok.status, 200);
  });

  test('turning it off needs the password and a code', async () => {
    const a = await signup(srv.base, 'tf_off');
    const { recovery } = await enable(a);
    const noCode = await api(srv.base, 'POST', '/api/me/2fa/disable', { token: a.token, body: { password: a.password } });
    assert.equal(noCode.body.error, 'otp_required');
    const ok = await api(srv.base, 'POST', '/api/me/2fa/disable', {
      token: a.token,
      body: { password: a.password, code: recovery[0] },
    });
    assert.equal(ok.status, 200);
    assert.equal((await signin(a)).status, 200);
  });
});
