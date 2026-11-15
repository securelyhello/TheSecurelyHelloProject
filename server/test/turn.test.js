import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { after, before, describe, test } from 'node:test';

import { api, signup, startServer } from './helpers.js';

const SECRET = 'turn-shared-secret-for-tests-0123456789';
const URLS = 'turn:turn.thenn.in:3478?transport=udp, turn:turn.thenn.in:3478?transport=tcp';

function captureLog() {
  const lines = [];
  const at = (level) => (msg, fields) => lines.push(JSON.stringify({ level, msg, ...fields }));
  return { lines, log: { debug: at('debug'), info: at('info'), warn: at('warn'), error: at('error') } };
}

describe('GET /api/turn (configured)', () => {
  let srv;
  const captured = captureLog();
  before(async () => {
    srv = await startServer({
      env: { TURN_SECRET: SECRET, TURN_URLS: URLS, TURN_TTL_SECONDS: '600' },
      log: captured.log,
      logRequests: true,
    });
  });
  after(() => srv.close());

  test('requires a session', async () => {
    assert.equal((await api(srv.base, 'GET', '/api/turn')).status, 401);
  });

  test('returns REST credentials that verify with an independent HMAC-SHA1', async () => {
    const a = await signup(srv.base, 'turn');
    const res = await fetch(`${srv.base}/api/turn`, { headers: { Authorization: `Bearer ${a.token}` } });
    assert.equal(res.status, 200);
    assert.equal(res.headers.get('cache-control'), 'no-store');
    const body = await res.json();
    assert.deepEqual(Object.keys(body).sort(), ['credential', 'ttl', 'urls', 'username']);
    assert.deepEqual(body.urls, ['turn:turn.thenn.in:3478?transport=udp', 'turn:turn.thenn.in:3478?transport=tcp']);
    assert.equal(body.ttl, 600);

    const [expiry, userId] = body.username.split(':');
    assert.equal(userId, a.id);
    assert.ok(body.username.endsWith(`:${a.id}`));
    const now = Math.floor(Date.now() / 1000);
    assert.ok(Math.abs(Number(expiry) - (now + 600)) <= 5, 'expiry is about now + ttl');

    const expected = createHmac('sha1', SECRET).update(body.username).digest('base64');
    assert.equal(body.credential, expected);
  });

  test('the secret never appears in responses or logs', async () => {
    const a = await signup(srv.base, 'turnsecret');
    const res = await api(srv.base, 'GET', '/api/turn', { token: a.token });
    assert.equal(JSON.stringify(res.body).includes(SECRET), false);
    assert.ok(captured.lines.length > 0, 'request logging was on');
    assert.equal(captured.lines.join('\n').includes(SECRET), false);
  });

  test('rate limited per account', async () => {
    const a = await signup(srv.base, 'turnlimit');
    const b = await signup(srv.base, 'turnother');
    const prev = srv.app.limits.defs.turnUser;
    srv.app.limits.defs.turnUser = { capacity: 2, perMs: 60 * 60_000 };
    try {
      assert.equal((await api(srv.base, 'GET', '/api/turn', { token: a.token })).status, 200);
      assert.equal((await api(srv.base, 'GET', '/api/turn', { token: a.token })).status, 200);
      const res = await api(srv.base, 'GET', '/api/turn', { token: a.token });
      assert.equal(res.status, 429);
      assert.equal(res.body.error, 'rate_limited');
      assert.equal((await api(srv.base, 'GET', '/api/turn', { token: b.token })).status, 200);
    } finally {
      srv.app.limits.defs.turnUser = prev;
    }
  });
});

describe('GET /api/turn (unconfigured)', () => {
  for (const env of [{}, { TURN_SECRET: SECRET }, { TURN_URLS: URLS }]) {
    test(`STUN-only answer with ${Object.keys(env).join('+') || 'nothing'} set`, async () => {
      const srv = await startServer({ env });
      try {
        const a = await signup(srv.base, 'turnoff');
        const res = await api(srv.base, 'GET', '/api/turn', { token: a.token });
        assert.equal(res.status, 200);
        assert.deepEqual(res.body, { urls: [], ttl: 0 });
      } finally {
        await srv.close();
      }
    });
  }
});

describe('TURN config', () => {
  test('loadConfig parses TURN_* with a 3600 s default ttl', async () => {
    const { loadConfig } = await import('../src/app.js');
    assert.deepEqual(loadConfig({ TURN_SECRET: 's', TURN_URLS: ' a ,, b ' }).turn, { secret: 's', urls: ['a', 'b'], ttl: 3600 });
    assert.deepEqual(loadConfig({}).turn, { secret: '', urls: [], ttl: 3600 });
    assert.equal(loadConfig({ TURN_TTL_SECONDS: '120' }).turn.ttl, 120);
  });
});
