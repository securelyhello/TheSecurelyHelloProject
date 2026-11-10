import { createHash, randomBytes, scrypt, timingSafeEqual } from 'node:crypto';
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
