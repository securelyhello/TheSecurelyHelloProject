// Push wake-ups for devices that are not connected.
//
// A push never carries message content, sender or conversation: it only says
// "something is waiting" so the app wakes, fetches its (encrypted) relay
// queue and decrypts locally. Notifications with names or previews are built
// on the device. Pushes are throttled per device (one per PUSH_THROTTLE_SECONDS)
// and skipped while the device has a live socket.
//
// Provider: Firebase Cloud Messaging HTTP v1 (Android, and iOS through FCM's
// APNs bridge). Configure with FCM_SERVICE_ACCOUNT: the service-account JSON,
// either inline, base64-encoded, or a path to the file.
import { createSign } from 'node:crypto';
import { readFileSync } from 'node:fs';

const FCM_SCOPE = 'https://www.googleapis.com/auth/firebase.messaging';

function loadServiceAccount(raw) {
  if (!raw) return null;
  const text = raw.trim();
  let json = text;
  if (!text.startsWith('{')) {
    try {
      json = readFileSync(text, 'utf8');
    } catch {
      json = Buffer.from(text, 'base64').toString('utf8');
    }
  }
  const sa = JSON.parse(json);
  if (!sa.client_email || !sa.private_key || !sa.project_id) {
    throw new Error('FCM_SERVICE_ACCOUNT must contain client_email, private_key and project_id');
  }
  return sa;
}

const b64url = (buf) => Buffer.from(buf).toString('base64url');

/**
 * FCM HTTP v1 sender. [fetchImpl] and [endpoint] are injectable for tests.
 * @returns {{send(token: string, kind: string): Promise<'ok'|'invalid_token'>}}
 */
export function createFcmSender(serviceAccount, { fetchImpl = fetch, endpoint } = {}) {
  const sa = serviceAccount;
  const tokenUri = sa.token_uri || 'https://oauth2.googleapis.com/token';
  const sendUri = endpoint || `https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`;
  let access = null; // {token, expiresAt}

  async function accessToken() {
    if (access && access.expiresAt > Date.now() + 60_000) return access.token;
    const now = Math.floor(Date.now() / 1000);
    const header = b64url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
    const claims = b64url(
      JSON.stringify({ iss: sa.client_email, scope: FCM_SCOPE, aud: tokenUri, iat: now, exp: now + 3600 }),
    );
    const signature = createSign('RSA-SHA256').update(`${header}.${claims}`).sign(sa.private_key);
    const res = await fetchImpl(tokenUri, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
        assertion: `${header}.${claims}.${b64url(signature)}`,
      }),
    });
    if (!res.ok) throw new Error(`FCM auth failed: ${res.status}`);
    const body = await res.json();
    access = { token: body.access_token, expiresAt: Date.now() + (body.expires_in ?? 3600) * 1000 };
    return access.token;
  }

  return {
    async send(token, kind) {
      const title = 'Securely Hello';
      const text = kind === 'request' ? 'You have a new contact request' : 'You have a new message';
      const res = await fetchImpl(sendUri, {
        method: 'POST',
        headers: { Authorization: `Bearer ${await accessToken()}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({
          message: {
            token,
            notification: { title, body: text },
            data: { type: kind },
            android: { priority: 'high', collapse_key: 'securelyhello', notification: { tag: 'securelyhello' } },
            apns: {
              headers: { 'apns-collapse-id': 'securelyhello', 'apns-priority': '10' },
              payload: { aps: { sound: 'default' } },
            },
          },
        }),
      });
      if (res.ok) return 'ok';
      const err = await res.json().catch(() => ({}));
      const code = err?.error?.details?.find?.((d) => d.errorCode)?.errorCode ?? err?.error?.status;
      if (res.status === 404 || code === 'UNREGISTERED' || code === 'INVALID_ARGUMENT') return 'invalid_token';
      throw new Error(`FCM send failed: ${res.status} ${code ?? ''}`);
    },
  };
}

/**
 * Decides when to wake which device.
 * @param {{pool, store, hub, sender, log, throttleSeconds?: number}} deps
 */
export function createNotifier({ pool, store, hub, sender, log, throttleSeconds = 30 }) {
  async function wakeDevice(userId, deviceId, kind) {
    if (!sender || hub.isDeviceConnected(userId, deviceId)) return false;
    const { rows } = await pool.query('SELECT push_token FROM devices WHERE id = $1 AND user_id = $2', [
      deviceId,
      userId,
    ]);
    const token = rows[0]?.push_token;
    if (!token) return false;
    if (!(await store.takePushSlot(deviceId, throttleSeconds))) return false;
    const result = await sender.send(token, kind);
    if (result === 'invalid_token') {
      await pool.query('UPDATE devices SET push_token = NULL, push_platform = NULL WHERE id = $1 AND push_token = $2', [
        deviceId,
        token,
      ]);
      log.info('push token dropped', { device: deviceId });
      return false;
    }
    return true;
  }

  return {
    enabled: Boolean(sender),
    wake: wakeDevice,
    /** Every device of [userId] that is not connected. */
    async wakeUser(userId, kind) {
      const { rows } = await pool.query('SELECT id FROM devices WHERE user_id = $1 AND push_token IS NOT NULL', [
        userId,
      ]);
      await Promise.all(rows.map((r) => wakeDevice(userId, r.id, kind)));
    },
  };
}

export function senderFromEnv(env = process.env, log) {
  try {
    const sa = loadServiceAccount(env.FCM_SERVICE_ACCOUNT);
    return sa ? createFcmSender(sa) : null;
  } catch (err) {
    log?.error('push disabled: bad FCM_SERVICE_ACCOUNT', { error: err.message });
    return null;
  }
}
