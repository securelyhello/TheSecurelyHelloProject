// Regression tests for findings of security audit run 1
// (docs/security-audit/run-1/REPORT.md). Each reproduces the verifier's
// scenario and expects it to fail now.
import assert from 'node:assert/strict';
import { existsSync, mkdtempSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, before, describe, test } from 'node:test';

import { filesystemStore } from '../src/blobstore.js';
import { base32Decode, hotp, stepAt } from '../src/twofactor.js';
import { addDevice, api, connectWs, makeContacts, signup, startServer } from './helpers.js';

const ADMIN = 'b'.repeat(40);

/** Resolves with the close code, or 'still open' after [ms]. */
const closeCode = (ws, ms = 3000) =>
  new Promise((resolve) => {
    const t = setTimeout(() => resolve('still open'), ms);
    ws.ws.once('close', (code) => {
      clearTimeout(t);
      resolve(code);
    });
  });

describe('audit run 1', () => {
  let srv;
  let dir;
  before(async () => {
    dir = mkdtempSync(path.join(tmpdir(), 'sh-audit-'));
    srv = await startServer({ blobs: filesystemStore(dir), env: { ADMIN_TOKEN: ADMIN } });
  });
  after(() => srv.close());

  test('U1-1: new recovery codes need the authenticator, not just the password', async () => {
    const a = await signup(srv.base, 'u11');
    const setup = await api(srv.base, 'POST', '/api/me/2fa/setup', { token: a.token, body: { password: a.password } });
    const secret = base32Decode(setup.body.secret);
    const on = await api(srv.base, 'POST', '/api/me/2fa/enable', { token: a.token, body: { code: hotp(secret, stepAt()) } });
    const passwordOnly = await api(srv.base, 'POST', '/api/me/2fa/recovery-codes', {
      token: a.token,
      body: { password: a.password },
    });
    assert.equal(passwordOnly.body.error, 'otp_required');
    const withCode = await api(srv.base, 'POST', '/api/me/2fa/recovery-codes', {
      token: a.token,
      body: { password: a.password, code: on.body.recovery_codes[0] },
    });
    assert.equal(withCode.status, 200);
  });

  test('U1-2: changing the password or signing out closes the sockets of ended sessions', async () => {
    const a = await signup(srv.base, 'u12');
    const other = await addDevice(srv.base, a);
    const ws = await connectWs(srv.wsUrl, other.token);
    const closed = closeCode(ws);
    const res = await api(srv.base, 'POST', '/api/auth/change-password', {
      token: a.token,
      body: { current_password: a.password, new_password: 'another long password' },
    });
    assert.equal(res.status, 204);
    assert.equal(await closed, 4001);

    const own = await connectWs(srv.wsUrl, a.token);
    const ownClosed = closeCode(own);
    await api(srv.base, 'POST', '/api/auth/signout', { token: a.token });
    assert.equal(await ownClosed, 4001);
    await ws.close();
    await own.close();
  });

  test('U1-3: a wrong reset code says invalid_code even for a suspended account', async () => {
    const a = await signup(srv.base, 'u13');
    await api(srv.base, 'POST', `/api/admin/users/${a.id}/suspend`, { headers: { authorization: `Bearer ${ADMIN}` } });
    const res = await api(srv.base, 'POST', '/api/auth/password/reset', {
      body: { email: a.email, code: '123456', new_password: 'a brand new password' },
    });
    assert.equal(res.body.error, 'invalid_code');
  });

  test('U3-4: deleting the account deletes its attachment files', async () => {
    const a = await signup(srv.base, 'u34');
    const b = await signup(srv.base, 'u34b');
    await makeContacts(srv.base, a, b);
    const up = await fetch(`${srv.base}/api/attachments`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${a.token}`, 'Content-Type': 'application/octet-stream' },
      body: randomBytes(5000),
    });
    const { id } = await up.json();
    const file = path.join(dir, id.slice(0, 2), `${id}.bin`);
    assert.equal(existsSync(file), true);
    assert.equal((await api(srv.base, 'DELETE', '/api/me', { token: a.token })).status, 204);
    assert.equal(existsSync(file), false);
  });
});

describe('audit run 1, with e-mail verification required', () => {
  let srv;
  before(async () => {
    srv = await startServer({ env: { EMAIL_VERIFICATION: 'required' } });
  });
  after(() => srv.close());

  const verify = (u) => srv.pool.query('UPDATE users SET email_verified_at = now() WHERE id = $1', [u.id]);

  test('U3-2: unverified accounts can neither create nor hand out working invites', async () => {
    const squatter = await signup(srv.base, 'u32s');
    const victim = await signup(srv.base, 'u32v');
    await verify(victim);
    assert.equal((await api(srv.base, 'POST', '/api/invites', { token: squatter.token })).body.error, 'email_unverified');

    // An invite made while verified stops working if the inviter isn't verified.
    await verify(squatter);
    const { body } = await api(srv.base, 'POST', '/api/invites', { token: squatter.token });
    await srv.pool.query('UPDATE users SET email_verified_at = NULL WHERE id = $1', [squatter.id]);
    const accept = await api(srv.base, 'POST', `/api/invites/${body.token}/accept`, { token: victim.token });
    assert.equal(accept.status, 404);
  });

  test('U3-1: an unverified address is never found by e-mail', async () => {
    const squatter = await signup(srv.base, 'u31s');
    const turnOn = await api(srv.base, 'PUT', '/api/me/discovery', {
      token: squatter.token,
      body: { email_discoverable: true },
    });
    assert.equal(turnOn.status, 403);
  });
});
