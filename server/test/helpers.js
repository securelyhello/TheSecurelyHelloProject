// Test harness: a throwaway database in the dev Postgres container, the app
// on an ephemeral port, and small HTTP / WebSocket clients.
//
// TEST_DATABASE_URL defaults to the scripts/dev.sh container. The database
// named in it is dropped and recreated for every test file.
import { generateKeyPairSync, randomBytes, randomUUID, sign } from 'node:crypto';

import pg from 'pg';
import WebSocket from 'ws';

import { createApp, loadConfig } from '../src/app.js';
import { createPool } from '../src/db.js';
import { createRedis } from '../src/hotstore.js';
import { silentLogger } from '../src/log.js';
import { approvalMessage, signedPreKeyMessage } from '../src/devices.js';
import { captureMailer } from '../src/mail.js';
import { migrate } from '../src/migrate.js';

export const TEST_DATABASE_URL =
  process.env.TEST_DATABASE_URL ?? 'postgresql://sh:sh_dev_password@127.0.0.1:55432/securelyhello_test';

async function recreateDatabase(url) {
  const target = new URL(url);
  const dbName = target.pathname.slice(1);
  if (!/^[a-z0-9_]+$/.test(dbName) || !dbName.includes('test')) {
    throw new Error(`Refusing to recreate database "${dbName}" (name must contain "test")`);
  }
  const admin = new URL(url);
  admin.pathname = '/postgres';
  const client = new pg.Client({ connectionString: admin.toString() });
  await client.connect();
  try {
    await client.query(`DROP DATABASE IF EXISTS ${dbName} WITH (FORCE)`);
    await client.query(`CREATE DATABASE ${dbName}`);
  } finally {
    await client.end();
  }
}

const generous = { capacity: 100_000, perMs: 60_000 };
export const GENEROUS_LIMITS = {
  authIp: generous,
  authAccount: generous,
  publicIp: generous,
  api: generous,
  relay: generous,
  contactRequest: generous,
  wsFrames: generous,
  wsConnect: generous,
  emailSend: generous,
  prekeyClaim: generous,
  upload: generous,
  report: generous,
  signupIp: generous,
  contactRequestNew: generous,
  otp: generous,
  invite: generous,
  inviteLookup: generous,
  discovery: generous,
};

export const TEST_REDIS_URL = process.env.TEST_REDIS_URL ?? 'redis://127.0.0.1:56379/15';

export async function startServer({
  limitOverrides = {},
  storeOptions = {},
  env = {},
  mailer = captureMailer(),
  pushSender = null,
  blobs,
} = {}) {
  await recreateDatabase(TEST_DATABASE_URL);
  const pool = createPool(TEST_DATABASE_URL, { max: 5 });
  await migrate(pool, { log: () => {} });
  const redis = createRedis(TEST_REDIS_URL);
  await redis.flushdb(); // database 15 is reserved for tests
  const config = { ...loadConfig({ POW_BITS: '0', ...env }), logRequests: false };
  const app = createApp({
    pool,
    redis,
    config,
    limitOverrides: { ...GENEROUS_LIMITS, ...limitOverrides },
    storeOptions,
    log: silentLogger,
    mailer,
    pushSender,
    ...(blobs ? { blobs } : {}),
  });
  const addr = await app.listen(0, '127.0.0.1');
  const base = `http://127.0.0.1:${addr.port}`;
  return {
    app,
    pool,
    redis,
    mailer,
    store: app.store,
    base,
    wsUrl: `ws://127.0.0.1:${addr.port}/api/ws`,
    async close() {
      await app.close();
      await pool.end();
      await redis.quit();
    },
  };
}

export async function api(base, method, path, { token, body, headers = {} } = {}) {
  const res = await fetch(base + path, {
    method,
    headers: {
      ...(body !== undefined ? { 'Content-Type': 'application/json' } : {}),
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...headers,
    },
    body: body === undefined ? undefined : typeof body === 'string' ? body : JSON.stringify(body),
  });
  const text = await res.text();
  let json;
  try {
    json = text ? JSON.parse(text) : undefined;
  } catch {
    json = text;
  }
  return { status: res.status, body: json };
}

export const fakeKey = () => randomBytes(32).toString('base64');

/** A device identity with a real Ed25519 key, so signed prekeys verify. */
export function newDeviceKeys({ prekeys = 5, firstPrekeyId = 1 } = {}) {
  const { publicKey, privateKey } = generateKeyPairSync('ed25519');
  const signingPub = Buffer.from(publicKey.export({ format: 'jwk' }).x, 'base64url').toString('base64');
  const spkKey = fakeKey();
  const spkId = 1;
  return {
    privateKey,
    body: {
      signing_public_key: signingPub,
      identity_public_key: fakeKey(),
      signed_prekey: {
        id: spkId,
        key: spkKey,
        signature: sign(null, signedPreKeyMessage(spkId, spkKey), privateKey).toString('base64'),
      },
      one_time_prekeys: Array.from({ length: prekeys }, (_, i) => ({ id: firstPrekeyId + i, key: fakeKey() })),
    },
  };
}

export function signSpk(privateKey, id, key) {
  return sign(null, signedPreKeyMessage(id, key), privateKey).toString('base64');
}

/** Registers a device for [token]; returns {deviceId, keys}. */
export async function registerDevice(base, token, opts = {}) {
  const keys = newDeviceKeys(opts);
  const res = await api(base, 'PUT', '/api/devices/current', {
    token,
    body: { ...keys.body, name: opts.name ?? 'test device', ...(opts.deviceId ? { device_id: opts.deviceId } : {}) },
  });
  if (res.status !== 201 && res.status !== 200) {
    throw new Error(`device registration failed: ${res.status} ${JSON.stringify(res.body)}`);
  }
  return { deviceId: res.body.device_id, keys };
}

let counter = 0;
/** Signs up and (unless device:false) registers a first device. */
export async function signup(base, name = `user${++counter}`, { device = true } = {}) {
  const username = `${name}_${randomUUID().slice(0, 6)}`.toLowerCase().slice(0, 30);
  const creds = {
    email: `${username}@example.test`,
    password: 'correct horse battery staple',
    username,
    display_name: name,
  };
  const res = await api(base, 'POST', '/api/auth/signup', { body: creds });
  if (res.status !== 201) throw new Error(`signup failed: ${res.status} ${JSON.stringify(res.body)}`);
  const user = { ...creds, token: res.body.token, id: res.body.user.user_id, user: res.body.user };
  if (device) {
    const d = await registerDevice(base, user.token);
    user.deviceId = d.deviceId;
    user.deviceKeys = d.keys;
  }
  return user;
}

/** Signs [user] in again as another device: {token, deviceId}. The new
 * device is approved by [user]'s device (its key signs the approval) unless
 * opts.approve === false. */
export async function addDevice(base, user, opts = {}) {
  const res = await api(base, 'POST', '/api/auth/signin', { body: { email: user.email, password: user.password } });
  if (res.status !== 200) throw new Error(`signin failed: ${res.status}`);
  const d = await registerDevice(base, res.body.token, opts);
  const added = { ...user, token: res.body.token, deviceId: d.deviceId, deviceKeys: d.keys };
  if (opts.approve !== false) {
    const ok = await approveDevice(base, user, added);
    if (ok.status !== 200) throw new Error(`approve failed: ${ok.status} ${JSON.stringify(ok.body)}`);
  }
  return added;
}

/** [approver]'s device signs [pending]'s keys and approves it. */
export function approveDevice(base, approver, pending, { signer = approver.deviceKeys.privateKey } = {}) {
  const msg = approvalMessage(
    pending.id,
    pending.deviceId,
    pending.deviceKeys.body.signing_public_key,
    pending.deviceKeys.body.identity_public_key,
  );
  return api(base, 'POST', `/api/devices/${pending.deviceId}/approve`, {
    token: approver.token,
    body: { signature: sign(null, msg, signer).toString('base64') },
  });
}

export async function makeContacts(base, a, b) {
  const req = await api(base, 'POST', '/api/contact-requests', { token: a.token, body: { receiver_id: b.id } });
  if (req.status !== 201) throw new Error(`request failed: ${req.status} ${JSON.stringify(req.body)}`);
  const acc = await api(base, 'POST', `/api/contact-requests/${req.body.id}/accept`, { token: b.token });
  if (acc.status !== 200) throw new Error(`accept failed: ${acc.status} ${JSON.stringify(acc.body)}`);
}

/** A well-formed v3 envelope from [sender]'s device to [recipientDevice]. */
export function envelopeFrom(sender, recipientDevice, overrides = {}) {
  return JSON.stringify({
    v: 3,
    id: randomUUID(),
    s: sender.id,
    sd: sender.deviceId,
    rd: recipientDevice,
    t: Date.now(),
    h: JSON.stringify({ dh: fakeKey(), pn: 0, n: 0 }),
    c: randomBytes(120).toString('base64'),
    ...overrides,
  });
}

/** Relays one envelope to each device in [devices] of [to]. */
export function relaySend(base, from, to, { devices = [to.deviceId], known = devices, envelopes } = {}) {
  return api(base, 'POST', '/api/relay', {
    token: from.token,
    body: {
      recipient_id: to.id,
      known_devices: known,
      messages: devices.map((d, i) => ({ device_id: d, envelope: envelopes?.[i] ?? envelopeFrom(from, d) })),
    },
  });
}

/** A WebSocket client that buffers frames so tests can await them in order. */
export async function connectWs(wsUrl, token) {
  const ws = new WebSocket(wsUrl, token ? { headers: { Authorization: `Bearer ${token}` } } : {});
  const frames = [];
  const waiters = [];
  ws.on('message', (data) => {
    const frame = JSON.parse(data.toString());
    const i = waiters.findIndex((w) => w.pred(frame));
    if (i >= 0) {
      const [w] = waiters.splice(i, 1);
      clearTimeout(w.timer);
      w.resolve(frame);
    } else {
      frames.push(frame);
    }
  });
  await new Promise((resolve, reject) => {
    ws.once('open', resolve);
    ws.once('unexpected-response', (_req, res) => reject(new Error(`ws rejected: ${res.statusCode}`)));
    ws.once('error', reject);
  });
  const client = {
    ws,
    frames,
    send: (obj) => ws.send(JSON.stringify(obj)),
    /** Resolves with the first (buffered or future) frame matching [pred]. */
    next(pred = () => true, timeoutMs = 3000) {
      const i = frames.findIndex(pred);
      if (i >= 0) return Promise.resolve(frames.splice(i, 1)[0]);
      return new Promise((resolve, reject) => {
        const w = { pred, resolve };
        w.timer = setTimeout(() => {
          waiters.splice(waiters.indexOf(w), 1);
          reject(new Error(`timed out waiting for frame; buffered: ${JSON.stringify(frames)}`));
        }, timeoutMs);
        waiters.push(w);
      });
    },
    /** Asserts no frame matching [pred] arrives within [ms]. */
    async none(pred, ms = 300) {
      try {
        const f = await client.next(pred, ms);
        throw new Error(`unexpected frame ${JSON.stringify(f)}`);
      } catch (err) {
        if (!String(err.message).startsWith('timed out')) throw err;
      }
    },
    close() {
      return new Promise((resolve) => {
        if (ws.readyState === WebSocket.CLOSED) return resolve();
        ws.once('close', resolve);
        ws.close();
      });
    },
  };
  return client;
}

export const ofType = (type, extra = () => true) => (f) => f.type === type && extra(f);
