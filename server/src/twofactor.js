// Two-step verification: TOTP (RFC 6238; SHA-1, 6 digits, 30 s, ±1 step)
// and ten single-use recovery codes.
//
// Once enabled, a code is needed to sign in, to reset the password by
// e-mail and to recover the account onto a new device by e-mail, so access
// to the inbox alone is not enough.
import { createCipheriv, createDecipheriv, createHash, createHmac, randomBytes, timingSafeEqual } from 'node:crypto';

import { withTransaction } from './db.js';
import { verifyPassword } from './security.js';
import { HttpError, bad } from './validate.js';

const PERIOD = 30;
const DIGITS = 6;
const RECOVERY_CODES = 10;
const B32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

export function base32Encode(buf) {
  let bits = 0;
  let value = 0;
  let out = '';
  for (const byte of buf) {
    value = (value << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      out += B32[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
  }
  if (bits > 0) out += B32[(value << (5 - bits)) & 31];
  return out;
}

export function base32Decode(str) {
  const clean = str.toUpperCase().replace(/[\s=-]/g, '');
  let bits = 0;
  let value = 0;
  const out = [];
  for (const ch of clean) {
    const i = B32.indexOf(ch);
    if (i < 0) throw new Error('invalid base32');
    value = (value << 5) | i;
    bits += 5;
    if (bits >= 8) {
      out.push((value >>> (bits - 8)) & 255);
      bits -= 8;
    }
  }
  return Buffer.from(out);
}

/** The code for time step [step] (RFC 4226 dynamic truncation). */
export function hotp(secret, step) {
  const counter = Buffer.alloc(8);
  counter.writeBigUInt64BE(BigInt(step));
  const mac = createHmac('sha1', secret).update(counter).digest();
  const off = mac[mac.length - 1] & 0xf;
  const n = mac.readUInt32BE(off) & 0x7fffffff;
  return String(n % 10 ** DIGITS).padStart(DIGITS, '0');
}

export const stepAt = (ms = Date.now()) => Math.floor(ms / 1000 / PERIOD);

/** Matching step within ±1 of now, or null. */
export function matchStep(secret, code, now = Date.now()) {
  if (typeof code !== 'string' || !/^\d{6}$/.test(code)) return null;
  const current = stepAt(now);
  for (const step of [current - 1, current, current + 1]) {
    const expected = Buffer.from(hotp(secret, step));
    if (timingSafeEqual(expected, Buffer.from(code))) return step;
  }
  return null;
}

const recoveryHash = (userId, code) =>
  createHash('sha256').update(`securelyhello-recovery|${userId}|${code.toLowerCase().replace(/[^a-z2-7]/g, '')}`).digest();

function newRecoveryCode() {
  const raw = base32Encode(randomBytes(7)).slice(0, 10).toLowerCase();
  return `${raw.slice(0, 5)}-${raw.slice(5)}`;
}

/** Seals TOTP secrets at rest when a key is configured. */
function secretBox(keyMaterial) {
  if (keyMaterial && keyMaterial.length < 32) {
    throw new Error('TOTP_ENCRYPTION_KEY must be at least 32 characters');
  }
  const key = keyMaterial ? createHash('sha256').update(keyMaterial).digest() : null;
  return {
    seal(secret) {
      if (!key) return `p:${secret.toString('base64')}`;
      const iv = randomBytes(12);
      const c = createCipheriv('aes-256-gcm', key, iv);
      const body = Buffer.concat([c.update(secret), c.final()]);
      return `g:${Buffer.concat([iv, c.getAuthTag(), body]).toString('base64')}`;
    },
    /** Stored without encryption although a key is configured now. */
    needsSealing: (stored) => key != null && stored.startsWith('p:'),
    open(stored) {
      const raw = Buffer.from(stored.slice(2), 'base64');
      if (stored.startsWith('p:')) return raw;
      if (!key) throw new Error('TOTP_ENCRYPTION_KEY is needed to read two-step secrets');
      const d = createDecipheriv('aes-256-gcm', key, raw.subarray(0, 12));
      d.setAuthTag(raw.subarray(12, 28));
      return Buffer.concat([d.update(raw.subarray(28)), d.final()]);
    },
  };
}

export function createTwoFactor({ pool, config, limits }) {
  const box = secretBox(config.totpKey);

  async function enabled(userId) {
    const { rows } = await pool.query('SELECT totp_enabled_at FROM users WHERE id = $1', [userId]);
    return rows[0]?.totp_enabled_at != null;
  }

  /** 'ok' (not enabled, or a valid unused code), 'required' or 'invalid'. */
  async function check(userId, code) {
    const { rows } = await pool.query('SELECT totp_secret, totp_enabled_at FROM users WHERE id = $1', [userId]);
    if (!rows[0]?.totp_enabled_at) return 'ok';
    if (code == null || code === '') return 'required';
    if (typeof code !== 'string' || code.length > 32) return 'invalid';
    if (!(await limits.take('otp', userId))) throw new HttpError(429, 'rate_limited', 'Too many attempts. Try again later.');

    const secret = box.open(rows[0].totp_secret);
    if (box.needsSealing(rows[0].totp_secret)) {
      await pool.query('UPDATE users SET totp_secret = $2 WHERE id = $1', [userId, box.seal(secret)]);
    }
    const step = matchStep(secret, code.trim());
    if (step != null) {
      const res = await pool.query(
        `UPDATE users SET totp_last_step = $2
          WHERE id = $1 AND (totp_last_step IS NULL OR totp_last_step < $2)`,
        [userId, step],
      );
      return res.rowCount === 1 ? 'ok' : 'invalid';
    }
    const used = await pool.query(
      `UPDATE totp_recovery_codes SET used_at = now()
        WHERE user_id = $1 AND code_hash = $2 AND used_at IS NULL`,
      [userId, recoveryHash(userId, code)],
    );
    return used.rowCount === 1 ? 'ok' : 'invalid';
  }

  /** Throws unless [code] satisfies two-step verification for [userId]. */
  async function require(userId, code) {
    const r = await check(userId, code);
    if (r === 'required') {
      throw new HttpError(401, 'otp_required', 'Enter the code from your authenticator app');
    }
    if (r === 'invalid') throw new HttpError(401, 'invalid_otp', 'That code is wrong or was already used');
  }

  async function newRecoveryCodes(client, userId) {
    const codes = Array.from({ length: RECOVERY_CODES }, newRecoveryCode);
    await client.query('DELETE FROM totp_recovery_codes WHERE user_id = $1', [userId]);
    for (const c of codes) {
      await client.query('INSERT INTO totp_recovery_codes (user_id, code_hash) VALUES ($1, $2)', [
        userId,
        recoveryHash(userId, c),
      ]);
    }
    return codes;
  }

  return { enabled, check, require, newRecoveryCodes, box };
}

export function registerTwoFactorRoutes(router, { pool, twoFactor, limits }) {
  async function checkPassword(userId, password) {
    if (!(await limits.take('authAccount', `pw:${userId}`))) {
      throw new HttpError(429, 'rate_limited', 'Too many attempts. Try again later.');
    }
    if (typeof password !== 'string' || password.length > 256) throw bad('password is required');
    const { rows } = await pool.query('SELECT password_hash, email FROM users WHERE id = $1', [userId]);
    if (!rows[0] || !(await verifyPassword(password, rows[0].password_hash))) {
      throw new HttpError(403, 'invalid_credentials', 'Password is wrong');
    }
    return rows[0];
  }

  router.add('GET', '/api/me/2fa', async ({ user }) => {
    const { rows } = await pool.query(
      `SELECT u.totp_enabled_at,
              (SELECT count(*)::int FROM totp_recovery_codes r WHERE r.user_id = u.id AND r.used_at IS NULL) AS left
         FROM users u WHERE u.id = $1`,
      [user.id],
    );
    return { enabled: rows[0]?.totp_enabled_at != null, recovery_codes_left: rows[0]?.left ?? 0 };
  });

  // Step 1: a new secret, kept pending until a code from it is confirmed.
  router.add('POST', '/api/me/2fa/setup', async ({ body, user }) => {
    const row = await checkPassword(user.id, body?.password);
    if (await twoFactor.enabled(user.id)) throw new HttpError(409, 'already_enabled', 'Two-step verification is on');
    const secret = randomBytes(20);
    await pool.query('UPDATE users SET totp_pending_secret = $2 WHERE id = $1', [user.id, twoFactor.box.seal(secret)]);
    const b32 = base32Encode(secret);
    const label = encodeURIComponent(`Securely Hello:${row.email}`);
    return {
      secret: b32,
      uri: `otpauth://totp/${label}?secret=${b32}&issuer=Securely%20Hello&algorithm=SHA1&digits=6&period=30`,
    };
  });

  // Step 2: prove the authenticator works; returns the recovery codes once.
  router.add('POST', '/api/me/2fa/enable', async ({ body, user }) => {
    if (!(await limits.take('otp', user.id))) throw new HttpError(429, 'rate_limited', 'Too many attempts');
    const { rows } = await pool.query('SELECT totp_pending_secret FROM users WHERE id = $1', [user.id]);
    const pending = rows[0]?.totp_pending_secret;
    if (!pending) throw new HttpError(409, 'no_setup', 'Start setup first');
    const step = matchStep(twoFactor.box.open(pending), String(body?.code ?? ''));
    if (step == null) throw new HttpError(400, 'invalid_otp', 'That code is wrong. Check the time on your phone.');
    const codes = await withTransaction(pool, async (client) => {
      await client.query(
        `UPDATE users SET totp_secret = totp_pending_secret, totp_pending_secret = NULL,
                totp_enabled_at = now(), totp_last_step = $2 WHERE id = $1`,
        [user.id, step],
      );
      return twoFactor.newRecoveryCodes(client, user.id);
    });
    return { enabled: true, recovery_codes: codes };
  });

  router.add('POST', '/api/me/2fa/disable', async ({ body, user }) => {
    await checkPassword(user.id, body?.password);
    await twoFactor.require(user.id, body?.code);
    await pool.query(
      `UPDATE users SET totp_secret = NULL, totp_pending_secret = NULL, totp_enabled_at = NULL,
              totp_last_step = NULL WHERE id = $1`,
      [user.id],
    );
    await pool.query('DELETE FROM totp_recovery_codes WHERE user_id = $1', [user.id]);
    return { enabled: false };
  });

  router.add('POST', '/api/me/2fa/recovery-codes', async ({ body, user }) => {
    await checkPassword(user.id, body?.password);
    if (!(await twoFactor.enabled(user.id))) throw new HttpError(409, 'not_enabled', 'Two-step verification is off');
    // New codes are as good as the authenticator, so they need it (audit run 1, U1-1).
    await twoFactor.require(user.id, body?.code);
    return { recovery_codes: await withTransaction(pool, (client) => twoFactor.newRecoveryCodes(client, user.id)) };
  });
}
