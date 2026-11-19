import assert from 'node:assert/strict';
import { after, before, describe, test } from 'node:test';

import { api, startServer } from './helpers.js';

// The app checks /api/config on start; a minimum version there makes old
// builds show a blocking "please update" screen (in-app updater, 1.1).
describe('minimum app version in /api/config', () => {
  let srv;
  let off;
  before(async () => {
    srv = await startServer({ env: { MIN_ANDROID_VERSION_CODE: '2' } });
    off = await startServer();
  });
  after(async () => {
    await srv.close();
    await off.close();
  });

  test('set: the config carries it', async () => {
    const r = await api(srv.base, 'GET', '/api/config');
    assert.equal(r.status, 200);
    assert.equal(r.body.min_android_version_code, 2);
  });

  test('unset: the config is unchanged (1.0 apps see what they always saw)', async () => {
    const r = await api(off.base, 'GET', '/api/config');
    assert.equal('min_android_version_code' in r.body, false);
  });
});
