import { createHash, createHmac, randomBytes, randomInt, scrypt, timingSafeEqual } from 'node:crypto';
import { promisify } from 'node:util';

const scryptAsync = promisify(scrypt);

// scrypt N=2^15, r=8, p=1 → 32 MiB per hash (OWASP-recommended minimum is 2^17
// for interactive logins on dedicated hardware; 2^15 keeps a small server
// responsive under the auth rate limit). Parameters are stored with the hash,
// so they can be raised later without invalidating existing passwords.
const SCRYPT = { N: 1 << 15, r: 8, p: 1, keyLen: 32 };

function scryptOpts({ N, r, p }) {
  return { N, r, p, maxmem: 128 * N * r * 2 };
}

/** Returns `scrypt$N$r$p$salt$hash` (base64). */
export async function hashPassword(password) {
  const salt = randomBytes(16);
  const key = await scryptAsync(password.normalize('NFKC'), salt, SCRYPT.keyLen, scryptOpts(SCRYPT));
  return ['scrypt', SCRYPT.N, SCRYPT.r, SCRYPT.p, salt.toString('base64'), key.toString('base64')].join('$');
}

export async function verifyPassword(password, stored) {
  const parts = typeof stored === 'string' ? stored.split('$') : [];
  if (parts.length !== 6 || parts[0] !== 'scrypt') return false;
  const [, n, r, p, saltB64, hashB64] = parts;
  const expected = Buffer.from(hashB64, 'base64');
  const params = { N: Number(n), r: Number(r), p: Number(p) };
  const key = await scryptAsync(
    password.normalize('NFKC'),
    Buffer.from(saltB64, 'base64'),
    expected.length,
    scryptOpts(params),
  );
  return key.length === expected.length && timingSafeEqual(key, expected);
}

// A fixed hash to verify against when the e-mail is unknown, so sign-in takes
// the same time whether or not the account exists.
let dummyHash;
export async function burnPasswordCheck(password) {
  dummyHash ??= await hashPassword('not-a-real-password');
  await verifyPassword(password, dummyHash);
}

/** 256-bit opaque bearer token; only its SHA-256 is stored. */
export function newSessionToken() {
  return randomBytes(32).toString('base64url');
}

export function hashToken(token) {
  return createHash('sha256').update(token, 'utf8').digest();
}

/** A uniformly random 6-digit code, zero-padded ("004219"). */
export function newEmailCode() {
  return String(randomInt(0, 1_000_000)).padStart(6, '0');
}

/**
 * HMAC-SHA256 of `purpose:userId:code` under the server's code key, so a
 * stored hash only matches its own user and purpose, and a leaked
 * auth_tokens table can't be brute-forced (10^6 codes) without the key.
 */
export function hashEmailCode(key, purpose, userId, code) {
  return createHmac('sha256', key).update(`${purpose}:${userId}:${code}`, 'utf8').digest();
}

/**
 * The HMAC key for e-mail codes: CODE_HMAC_KEY when set, otherwise 32 random
 * bytes for this process. Codes live 30 minutes at most, so a random key only
 * means a restart invalidates codes that are still live; with several
 * instances behind one database, set CODE_HMAC_KEY so they agree.
 */
export function resolveCodeKey(value, { production = false, log } = {}) {
  const configured = typeof value === 'string' ? value.trim() : '';
  if (configured) return Buffer.from(configured, 'utf8');
  if (production) {
    log?.warn('CODE_HMAC_KEY is not set: using a random per-process key; a restart invalidates live e-mail codes');
  }
  return randomBytes(32);
}

/** Constant-time comparison of two hashes (false on length mismatch). */
export function hashesEqual(a, b) {
  return Buffer.isBuffer(a) && Buffer.isBuffer(b) && a.length === b.length && timingSafeEqual(a, b);
}
