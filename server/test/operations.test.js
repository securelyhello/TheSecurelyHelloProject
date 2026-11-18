import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { after, before, describe, test } from 'node:test';

import { loadConfig } from '../src/app.js';
import { api, signup, startServer } from './helpers.js';

const TOKEN = 'm'.repeat(40);
let srv;
before(async () => {
  srv = await startServer({
    env: { METRICS_TOKEN: TOKEN, TURN_URLS: 'turn:turn.example:3478, turns:turn.example:5349', TURN_SECRET: 'shared-secret' },
  });
});
after(() => srv.close());

const metrics = (auth) =>
  fetch(`${srv.base}/metrics`, auth ? { headers: { Authorization: auth } } : {}).then(async (r) => ({
    status: r.status,
    type: r.headers.get('content-type'),
    text: await r.text(),
  }));

describe('operations', () => {
  test('metrics need the operator token and carry no user data', async () => {
    const a = await signup(srv.base, 'ops_user');
    await api(srv.base, 'GET', `/api/users/${a.id}`, { token: a.token });
    assert.equal((await metrics()).status, 401);
    assert.equal((await metrics('Bearer wrong')).status, 401);
    const m = await metrics(`Bearer ${TOKEN}`);
    assert.equal(m.status, 200);
    assert.match(m.type, /^text\/plain/);
    assert.match(m.text, /sh_http_requests_total\{method="GET",route="\/api\/users\/:id",status="200"\} 1/);
    assert.match(m.text, /sh_http_request_duration_seconds_count\{route="\/api\/users\/:id"\} 1/);
    assert.match(m.text, /sh_ws_connections 0/);
    assert.ok(!m.text.includes(a.id) && !m.text.includes(a.username), 'route patterns only, never ids');
  });

  test('TURN credentials expire and verify with the shared secret', async () => {
    const a = await signup(srv.base, 'ops_turn');
    assert.equal((await api(srv.base, 'GET', '/api/turn')).status, 401, 'signed-in users only');
    const { body } = await api(srv.base, 'GET', '/api/turn', { token: a.token });
    assert.deepEqual(body.urls, ['turn:turn.example:3478', 'turns:turn.example:5349']);
    const expiry = Number(body.username.split(':')[0]);
    const inHours = (expiry - Date.now() / 1000) / 3600;
    assert.ok(inHours > 11.9 && inHours <= 12, `expires in 12 h, not ${inHours}`);
    assert.equal(body.credential, createHmac('sha1', 'shared-secret').update(body.username).digest('base64'));
    const again = await api(srv.base, 'GET', '/api/turn', { token: a.token });
    assert.notEqual(again.body.username, body.username, 'a fresh one each time');
  });

  test('the sign-up cap per address can be raised', () => {
    assert.equal(loadConfig({}).signupsPerIp, 0, 'unset: the built-in 10 a day');
    assert.equal(loadConfig({ SIGNUPS_PER_IP_PER_DAY: '100' }).signupsPerIp, 100);
  });

  test('without the settings, metrics and TURN are off', async () => {
    const plain = await startServer();
    try {
      assert.equal((await fetch(`${plain.base}/metrics`)).status, 404);
      const a = await signup(plain.base, 'ops_off');
      assert.deepEqual((await api(plain.base, 'GET', '/api/turn', { token: a.token })).body, { urls: [] });
    } finally {
      await plain.close();
    }
  });
});
