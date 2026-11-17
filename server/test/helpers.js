// Test harness: a throwaway database in the dev Postgres container, the app
// on an ephemeral port, and small HTTP / WebSocket clients.
//
// TEST_DATABASE_URL defaults to the scripts/dev.sh container. The database
// named in it is dropped and recreated for every test file.
import { randomBytes, randomUUID } from 'node:crypto';

import pg from 'pg';
import WebSocket from 'ws';

import { createApp, loadConfig } from '../src/app.js';
import { createPool } from '../src/db.js';
import { createRedis } from '../src/hotstore.js';
import { silentLogger } from '../src/log.js';
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
};

export const TEST_REDIS_URL = process.env.TEST_REDIS_URL ?? 'redis://127.0.0.1:56379/15';

export async function startServer({ limitOverrides = {}, storeOptions = {}, env = {}, mailer = captureMailer() } = {}) {
  await recreateDatabase(TEST_DATABASE_URL);
  const pool = createPool(TEST_DATABASE_URL, { max: 5 });
  await migrate(pool, { log: () => {} });
  const redis = createRedis(TEST_REDIS_URL);
  await redis.flushdb(); // database 15 is reserved for tests
  const config = { ...loadConfig(env), logRequests: false };
  const app = createApp({
    pool,
    redis,
    config,
    limitOverrides: { ...GENEROUS_LIMITS, ...limitOverrides },
    storeOptions,
    log: silentLogger,
    mailer,
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

let counter = 0;
export async function signup(base, name = `user${++counter}`) {
  const username = `${name}_${randomUUID().slice(0, 6)}`.toLowerCase().slice(0, 30);
  const creds = {
    email: `${username}@example.test`,
    password: 'correct horse battery staple',
    username,
    display_name: name,
    signing_public_key: fakeKey(),
    encryption_public_key: fakeKey(),
  };
  const res = await api(base, 'POST', '/api/auth/signup', { body: creds });
  if (res.status !== 201) throw new Error(`signup failed: ${res.status} ${JSON.stringify(res.body)}`);
  return { ...creds, token: res.body.token, id: res.body.user.user_id, user: res.body.user };
}

export async function makeContacts(base, a, b) {
  const req = await api(base, 'POST', '/api/contact-requests', { token: a.token, body: { receiver_id: b.id } });
  if (req.status !== 201) throw new Error(`request failed: ${req.status} ${JSON.stringify(req.body)}`);
  const acc = await api(base, 'POST', `/api/contact-requests/${req.body.id}/accept`, { token: b.token });
  if (acc.status !== 200) throw new Error(`accept failed: ${acc.status} ${JSON.stringify(acc.body)}`);
}

export function envelopeFrom(senderId) {
  return JSON.stringify({
    v: 2,
    id: randomUUID(),
    s: senderId,
    t: Date.now(),
    c: randomBytes(120).toString('base64'),
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
