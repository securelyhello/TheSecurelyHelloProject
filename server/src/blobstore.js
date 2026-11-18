// Where attachment ciphertext lives. Metadata (owner, size, expiry) is always
// in Postgres; the bytes go to one of:
//
//   ATTACHMENT_STORAGE=postgres     the attachments.data column (default)
//   ATTACHMENT_STORAGE=filesystem   files under ATTACHMENT_DIR (e.g. a volume on your VPS)
//   ATTACHMENT_STORAGE=s3           any S3-compatible store (MinIO, AWS, R2, B2, …):
//       S3_ENDPOINT (https://s3.example.com), S3_BUCKET, S3_REGION (default us-east-1),
//       S3_ACCESS_KEY_ID, S3_SECRET_ACCESS_KEY, S3_PATH_STYLE (default 1; MinIO needs it)
//
// Every blob is already encrypted by the client; the store never sees a key.
import { createHash, createHmac } from 'node:crypto';
import { mkdir, readFile, rename, rm, writeFile } from 'node:fs/promises';
import path from 'node:path';

const ID_RE = /^[0-9a-f-]{36}$/;

function checkId(id) {
  if (!ID_RE.test(id)) throw new Error('bad blob id');
  return id;
}

/** Bytes in the attachments.data column. */
export function postgresStore(pool) {
  return {
    kind: 'postgres',
    async put(id, bytes, client = pool) {
      await client.query('UPDATE attachments SET data = $2 WHERE id = $1', [id, bytes]);
    },
    async get(id) {
      const { rows } = await pool.query('SELECT data FROM attachments WHERE id = $1', [id]);
      return rows[0]?.data ?? null;
    },
    async delete() {
      // The row itself is deleted by the caller.
    },
  };
}

/** One file per blob under [dir], fanned out by the first two hex digits. */
export function filesystemStore(dir) {
  if (!dir) throw new Error('ATTACHMENT_STORAGE=filesystem needs ATTACHMENT_DIR');
  const fileFor = (id) => path.join(dir, checkId(id).slice(0, 2), `${id}.bin`);
  return {
    kind: 'filesystem',
    dir,
    async put(id, bytes) {
      const file = fileFor(id);
      await mkdir(path.dirname(file), { recursive: true });
      const tmp = `${file}.${process.pid}.tmp`;
      await writeFile(tmp, bytes, { mode: 0o600 });
      await rename(tmp, file); // atomic: a reader never sees half a file
    },
    async get(id) {
      try {
        return await readFile(fileFor(id));
      } catch (err) {
        if (err.code === 'ENOENT') return null;
        throw err;
      }
    },
    async delete(id) {
      await rm(fileFor(id), { force: true });
    },
  };
}

// AWS Signature Version 4 (no SDK)

const sha256Hex = (data) => createHash('sha256').update(data).digest('hex');
const hmac = (key, data) => createHmac('sha256', key).update(data).digest();

/** RFC 3986 encoding as SigV4 wants it (keeps / in paths when asked). */
export function uriEncode(str, keepSlash = false) {
  const out = encodeURIComponent(str).replace(/[!'()*]/g, (c) => `%${c.charCodeAt(0).toString(16).toUpperCase()}`);
  return keepSlash ? out.replace(/%2F/g, '/') : out;
}

/**
 * Signs a request; returns the headers to send (including Authorization).
 * [headers] must include host. [payloadHash] defaults to the SHA-256 of
 * [body]; S3 also wants it as x-amz-content-sha256.
 */
export function signV4({
  method,
  url,
  headers,
  body = '',
  region,
  service,
  accessKeyId,
  secretAccessKey,
  date = new Date(),
  payloadHash = sha256Hex(body),
  signPayloadHeader = true,
}) {
  const u = new URL(url);
  const amzDate = date.toISOString().replace(/[:-]|\.\d{3}/g, '');
  const day = amzDate.slice(0, 8);
  const all = { ...headers, 'x-amz-date': amzDate };
  if (signPayloadHeader) all['x-amz-content-sha256'] = payloadHash;
  const names = Object.keys(all).map((k) => k.toLowerCase()).sort();
  const lower = Object.fromEntries(Object.entries(all).map(([k, v]) => [k.toLowerCase(), String(v).trim().replace(/\s+/g, ' ')]));
  const canonicalHeaders = names.map((n) => `${n}:${lower[n]}\n`).join('');
  const signedHeaders = names.join(';');
  const query = [...u.searchParams.entries()]
    .map(([k, v]) => [uriEncode(k), uriEncode(v)])
    .sort(([a, x], [b, y]) => (a === b ? (x < y ? -1 : 1) : a < b ? -1 : 1))
    .map(([k, v]) => `${k}=${v}`)
    .join('&');
  const canonicalPath = u.pathname
    .split('/')
    .map((seg) => uriEncode(decodeURIComponent(seg)))
    .join('/');
  const canonicalRequest = [method, canonicalPath || '/', query, canonicalHeaders, signedHeaders, payloadHash].join('\n');
  const scope = `${day}/${region}/${service}/aws4_request`;
  const toSign = ['AWS4-HMAC-SHA256', amzDate, scope, sha256Hex(canonicalRequest)].join('\n');
  const kDate = hmac(`AWS4${secretAccessKey}`, day);
  const kSigning = hmac(hmac(hmac(kDate, region), service), 'aws4_request');
  const signature = createHmac('sha256', kSigning).update(toSign).digest('hex');
  return {
    ...all,
    Authorization: `AWS4-HMAC-SHA256 Credential=${accessKeyId}/${scope}, SignedHeaders=${signedHeaders}, Signature=${signature}`,
  };
}

/** S3-compatible object store. [fetchImpl] is injectable for tests. */
export function s3Store(env, { fetchImpl = fetch } = {}) {
  const endpoint = (env.S3_ENDPOINT || '').replace(/\/+$/, '');
  const bucket = env.S3_BUCKET;
  const region = env.S3_REGION || 'us-east-1';
  const accessKeyId = env.S3_ACCESS_KEY_ID;
  const secretAccessKey = env.S3_SECRET_ACCESS_KEY;
  if (!endpoint || !bucket || !accessKeyId || !secretAccessKey) {
    throw new Error('ATTACHMENT_STORAGE=s3 needs S3_ENDPOINT, S3_BUCKET, S3_ACCESS_KEY_ID and S3_SECRET_ACCESS_KEY');
  }
  const pathStyle = (env.S3_PATH_STYLE ?? '1') !== '0';
  const prefix = (env.S3_PREFIX ?? 'attachments/').replace(/^\/+/, '');

  function urlFor(id) {
    const key = `${prefix}${checkId(id)}.bin`;
    const base = new URL(endpoint);
    return pathStyle
      ? `${base.origin}/${bucket}/${uriEncode(key, true)}`
      : `${base.protocol}//${bucket}.${base.host}/${uriEncode(key, true)}`;
  }

  async function send(method, id, body) {
    const url = urlFor(id);
    const payload = body ?? Buffer.alloc(0);
    const headers = signV4({
      method,
      url,
      headers: {
        host: new URL(url).host,
        ...(body ? { 'content-type': 'application/octet-stream', 'content-length': String(payload.length) } : {}),
      },
      body: payload,
      region,
      service: 's3',
      accessKeyId,
      secretAccessKey,
    });
    delete headers.host; // fetch sets it
    return fetchImpl(url, { method, headers, body: body ? payload : undefined });
  }

  return {
    kind: 's3',
    async put(id, bytes) {
      const res = await send('PUT', id, Buffer.from(bytes));
      if (!res.ok) throw new Error(`S3 PUT failed: ${res.status} ${await res.text().catch(() => '')}`.slice(0, 300));
    },
    async get(id) {
      const res = await send('GET', id);
      if (res.status === 404) return null;
      if (!res.ok) throw new Error(`S3 GET failed: ${res.status}`);
      return Buffer.from(await res.arrayBuffer());
    },
    async delete(id) {
      const res = await send('DELETE', id);
      if (!res.ok && res.status !== 404) throw new Error(`S3 DELETE failed: ${res.status}`);
    },
  };
}

export function createBlobStore(env, pool, opts = {}) {
  const kind = (env.ATTACHMENT_STORAGE || 'postgres').toLowerCase();
  if (kind === 'postgres') return postgresStore(pool);
  if (kind === 'filesystem') return filesystemStore(env.ATTACHMENT_DIR);
  if (kind === 's3') return s3Store(env, opts);
  throw new Error(`Unknown ATTACHMENT_STORAGE "${kind}"`);
}
