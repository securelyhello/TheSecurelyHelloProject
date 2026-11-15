// Input validation. Every handler validates its own input through these
// helpers; anything that fails throws an HttpError(400).

export class HttpError extends Error {
  constructor(status, code, message) {
    super(message ?? code);
    this.status = status;
    this.code = code;
  }
}

export const bad = (message, code = 'invalid_input') => new HttpError(400, code, message);

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const USERNAME_RE = /^[a-z0-9_]{3,30}$/;
// Lenient: what signup used to accept. Sign-in keeps using it so nobody with
// an existing stored address is locked out.
const EMAIL_RE = /^[^\s@]{1,64}@[^\s@]{1,189}\.[^\s@]{1,63}$/;
// Strict, for new addresses (signup) and reset requests: printable ASCII
// only, no <, >, comma, quotes, backtick, backslash, spaces or control chars.
// ASCII-only also means JS toLowerCase() equals Postgres lower(), so
// rate-limit keys match the account the lookup finds (no 'vİctim' variants).
const STRICT_EMAIL_RE =
  /^[A-Za-z0-9.!#$%&*+/=?^_{|}~-]{1,64}@(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z0-9-]{2,63}$/;
// 32-byte keys, standard base64 with padding (what the Dart client emits).
const KEY_RE = /^[A-Za-z0-9+/]{43}=$/;

export function requireObject(body) {
  if (body === null || typeof body !== 'object' || Array.isArray(body)) {
    throw bad('JSON object body required');
  }
  return body;
}

export function uuid(value, field = 'id') {
  if (typeof value !== 'string' || !UUID_RE.test(value)) throw bad(`${field} must be a UUID`);
  return value.toLowerCase();
}

export function isUuid(value) {
  return typeof value === 'string' && UUID_RE.test(value);
}

export function username(value, field = 'username') {
  if (typeof value !== 'string') throw bad(`${field} is required`);
  const v = value.trim().toLowerCase();
  if (!USERNAME_RE.test(v)) {
    throw bad(`${field} must be 3-30 characters: a-z, 0-9 or _`, 'invalid_username');
  }
  return v;
}

/** @param {{strict?: boolean}} [opts] strict for signup and reset requests. */
export function email(value, { strict = false } = {}) {
  if (typeof value !== 'string') throw bad('email is required');
  const v = value.trim();
  if (v.length > 254 || !(strict ? STRICT_EMAIL_RE : EMAIL_RE).test(v)) {
    throw bad('A valid email is required', 'invalid_email');
  }
  return v;
}

export function password(value, field = 'password') {
  if (typeof value !== 'string') throw bad(`${field} is required`);
  // Upper bound stops scrypt being fed megabytes; lower bound is a policy.
  if (value.length < 8 || value.length > 256) {
    throw bad(`${field} must be 8-256 characters`, 'weak_password');
  }
  return value;
}

const CODE_RE = /^[0-9]{6}$/;

/** A 6-digit e-mail code. Any malformed value is the same 400 invalid_code as a wrong one. */
export function code(value) {
  const v = typeof value === 'string' ? value.trim() : '';
  if (!CODE_RE.test(v)) throw bad('Invalid or expired code', 'invalid_code');
  return v;
}

export function displayName(value) {
  if (typeof value !== 'string') throw bad('display_name is required');
  const v = value.trim().replace(/[\u0000-\u001f\u007f]/g, '');
  if (v.length < 1 || v.length > 64) throw bad('display_name must be 1-64 characters');
  return v;
}

export function publicKey(value, field) {
  if (typeof value !== 'string' || !KEY_RE.test(value)) {
    throw bad(`${field} must be a base64-encoded 32-byte public key`);
  }
  return value;
}

export function string(value, field, { min = 1, max }) {
  if (typeof value !== 'string' || value.length < min || value.length > max) {
    throw bad(`${field} must be a string of ${min}-${max} characters`);
  }
  return value;
}

export function optionalNickname(value) {
  if (value === undefined || value === null) return null;
  if (typeof value !== 'string' || value.length > 64) throw bad('nickname must be at most 64 characters');
  const v = value.trim();
  return v.length ? v : null;
}

/** Escapes LIKE wildcards so user input matches literally. */
export function escapeLike(value) {
  return value.replace(/[\\%_]/g, (c) => `\\${c}`);
}
