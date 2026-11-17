// File <-> string codec ("FTS1"): JavaScript port of tools/file_to_string.py,
// wire compatible with it and with lib/core/chat/file_string_codec.dart.
//
//   FILE   -> bytes -> gzip (only if smaller) -> SHA-256 of the original
//          -> base64 or base45 (RFC 9285) -> "FTS1|<meta>|<payload>"
//   STRING -> parse -> decode -> gunzip (if flagged) -> check size + SHA-256
//
// Chunks: "FTS1C|<session>|<i>/<total>|<piece>", reassembled in any order.
//
// Stricter than the reference when reading: the file name is reduced to a
// base name (no path traversal), gunzip stops at the declared size (no gzip
// bomb), and every base45 character is validated.
//
// The string is not encrypted: carry it only inside an end-to-end encrypted
// payload, or encrypt the bytes first.
import { createHash, randomBytes } from 'node:crypto';
import { gunzipSync, gzipSync } from 'node:zlib';

export const MAGIC = 'FTS1';
export const CHUNK_MAGIC = 'FTS1C';
export const ENCODINGS = ['base64', 'base45'];
export const MAX_DECODED_BYTES = 64 * 1024 * 1024;

export class FileStringError extends Error {}

/** Base45 uses ' ' as a digit, so only line breaks may be stripped. */
const stripNewlines = (t) => String(t).replace(/^[\r\n]+|[\r\n]+$/g, '');

const B45 = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:';
const B45_INDEX = new Map([...B45].map((c, i) => [c, i]));

export function base45Encode(data) {
  let out = '';
  for (let i = 0; i + 1 < data.length; i += 2) {
    let n = data[i] * 256 + data[i + 1];
    const c = n % 45;
    n = Math.floor(n / 45);
    out += B45[c] + B45[n % 45] + B45[Math.floor(n / 45)];
  }
  if (data.length % 2 === 1) {
    const n = data[data.length - 1];
    out += B45[n % 45] + B45[Math.floor(n / 45)];
  }
  return out;
}

export function base45Decode(s) {
  const idx = (ch) => {
    const v = B45_INDEX.get(ch);
    if (v === undefined) throw new FileStringError(`Invalid base45 character: ${JSON.stringify(ch)}`);
    return v;
  };
  if (s.length % 3 === 1) throw new FileStringError('Invalid base45 string length');
  const full = Math.floor(s.length / 3);
  const out = Buffer.alloc(full * 2 + (s.length % 3 === 2 ? 1 : 0));
  for (let i = 0; i < full; i++) {
    const n = idx(s[i * 3]) + idx(s[i * 3 + 1]) * 45 + idx(s[i * 3 + 2]) * 2025;
    if (n > 0xffff) throw new FileStringError('Invalid base45 triplet (out of range)');
    out[i * 2] = n >> 8;
    out[i * 2 + 1] = n & 0xff;
  }
  if (s.length % 3 === 2) {
    const n = idx(s[full * 3]) + idx(s[full * 3 + 1]) * 45;
    if (n > 0xff) throw new FileStringError('Invalid base45 pair (out of range)');
    out[full * 2] = n;
  }
  return out;
}

/** Python's json.dumps(..., separators=(",", ":")) with ensure_ascii. */
function asciiJson(value) {
  return JSON.stringify(value).replace(/[\u0080-\uffff]/g, (c) => `\\u${c.charCodeAt(0).toString(16).padStart(4, '0')}`);
}

/** bytes -> "FTS1|meta|payload" (matches encode_file()). */
export function encode(bytes, { filename, encoding = 'base64', compress = true } = {}) {
  if (!ENCODINGS.includes(encoding)) throw new FileStringError(`encoding must be one of ${ENCODINGS}`);
  const raw = Buffer.from(bytes);
  const sha256 = createHash('sha256').update(raw).digest('hex');
  let payload = raw;
  let compressed = false;
  if (compress) {
    const z = gzipSync(raw, { level: 9 });
    if (z.length < raw.length) {
      payload = z;
      compressed = true;
    }
  }
  const payloadText = encoding === 'base64' ? payload.toString('base64') : base45Encode(payload);
  const meta = asciiJson({ filename, size: raw.length, sha256, compressed, encoding });
  // urlsafe base64 *with* padding, like Python's urlsafe_b64encode.
  const metaB64 = Buffer.from(meta, 'utf8').toString('base64').replace(/\+/g, '-').replace(/\//g, '_');
  return `${MAGIC}|${metaB64}|${payloadText}`;
}

/** A plain file name: no directories, no "..", no control characters. */
export function safeFilename(raw) {
  let name = typeof raw === 'string' ? raw : '';
  name = name.replace(/\\/g, '/').split('/').pop();
  name = name.replace(/[\u0000-\u001f\u007f]/g, '').trim();
  if (!name || name === '.' || name === '..') return 'file';
  return name.length > 255 ? name.slice(-255) : name;
}

/** "FTS1|meta|payload" -> {filename, bytes, sha256}. Throws FileStringError. */
export function decode(s, { maxBytes = MAX_DECODED_BYTES } = {}) {
  const text = stripNewlines(s);
  const first = text.indexOf('|');
  const second = first < 0 ? -1 : text.indexOf('|', first + 1);
  if (first < 0 || second < 0) throw new FileStringError("Malformed string: expected 'MAGIC|meta|payload'");
  const magic = text.slice(0, first);
  if (magic !== MAGIC) throw new FileStringError(`Unrecognized format magic: ${JSON.stringify(magic)}`);

  let meta;
  try {
    meta = JSON.parse(Buffer.from(text.slice(first + 1, second), 'base64url').toString('utf8'));
  } catch {
    throw new FileStringError('Malformed metadata');
  }
  const { size, sha256, encoding, compressed } = meta ?? {};
  if (!Number.isSafeInteger(size) || size < 0 || typeof sha256 !== 'string' || typeof compressed !== 'boolean') {
    throw new FileStringError('Malformed metadata');
  }
  if (size > maxBytes) throw new FileStringError(`File too large (${size} bytes, limit ${maxBytes})`);

  const payloadText = text.slice(second + 1);
  let payload;
  if (encoding === 'base64') {
    if (!/^[A-Za-z0-9+/]*={0,2}$/.test(payloadText)) throw new FileStringError('Invalid payload text');
    payload = Buffer.from(payloadText, 'base64');
  } else if (encoding === 'base45') {
    payload = base45Decode(payloadText);
  } else {
    throw new FileStringError(`Unknown encoding in metadata: ${encoding}`);
  }

  let raw = payload;
  if (compressed) {
    try {
      // Stops at the declared size + 1: a lying meta can't make us inflate more.
      raw = gunzipSync(payload, { maxOutputLength: size + 1 });
    } catch (err) {
      if (err.code === 'ERR_BUFFER_TOO_LARGE') {
        throw new FileStringError(`Decompressed data exceeds the declared size (${size})`);
      }
      throw new FileStringError('Corrupt compressed payload');
    }
  }
  if (raw.length !== size) throw new FileStringError(`Size mismatch: expected ${size}, got ${raw.length}`);
  const actual = createHash('sha256').update(raw).digest('hex');
  if (actual !== sha256.toLowerCase()) {
    throw new FileStringError(`Integrity check failed: expected sha256 ${sha256}, got ${actual}`);
  }
  return { filename: safeFilename(meta.filename), bytes: raw, sha256: actual };
}

/** Splits into "FTS1C|session|i/total|piece" chunks (matches chunk_string()). */
export function chunk(s, { chunkSize = 400, sessionId } = {}) {
  if (!(chunkSize >= 1)) throw new FileStringError('chunkSize must be >= 1');
  const session = sessionId ?? randomBytes(4).toString('hex');
  const pieces = [];
  for (let i = 0; i < s.length; i += chunkSize) pieces.push(s.slice(i, i + chunkSize));
  return pieces.map((p, i) => `${CHUNK_MAGIC}|${session}|${i + 1}/${pieces.length}|${p}`);
}

/** Reassembles chunks given in any order (matches reassemble_chunks()). */
export function reassemble(chunks) {
  const parsed = new Map();
  const sessions = new Set();
  let total = null;
  for (const c of chunks) {
    const text = stripNewlines(c);
    const parts = [];
    let rest = text;
    while (parts.length < 3 && rest.includes('|')) {
      const i = rest.indexOf('|');
      parts.push(rest.slice(0, i));
      rest = rest.slice(i + 1);
    }
    parts.push(rest);
    if (parts.length !== 4 || parts[0] !== CHUNK_MAGIC) throw new FileStringError(`Not a chunk record: ${parts[0]}`);
    const m = /^(\d+)\/(\d+)$/.exec(parts[2]);
    const i = m ? Number(m[1]) : NaN;
    const t = m ? Number(m[2]) : NaN;
    if (!m || i < 1 || i > t) throw new FileStringError(`Bad chunk index: ${parts[2]}`);
    if (total !== null && total !== t) throw new FileStringError('Chunks disagree about the total');
    total = t;
    sessions.add(parts[1]);
    parsed.set(i, parts[3]);
  }
  if (sessions.size > 1) throw new FileStringError(`Chunks from multiple sessions mixed together: ${[...sessions]}`);
  if (total === null) throw new FileStringError('No chunks');
  const missing = [];
  for (let i = 1; i <= total; i++) if (!parsed.has(i)) missing.push(i);
  if (missing.length) throw new FileStringError(`Missing chunk(s): [${missing.join(', ')}]`);
  return Array.from({ length: total }, (_, k) => parsed.get(k + 1)).join('');
}
