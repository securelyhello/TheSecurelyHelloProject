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
// inline or base64-encoded.
import { createSign } from 'node:crypto';

const FCM_SCOPE = 'https://www.googleapis.com/auth/firebase.messaging';

// Fixed, not taken from the service-account file: the signed assertion sent
// there is a credential, and a tampered file must not be able to redirect it.
const GOOGLE_TOKEN_URL = 'https://oauth2.googleapis.com/token';
const PROJECT_ID = /^[a-z][a-z0-9-]{4,28}[a-z0-9]$/;

function loadServiceAccount(raw) {
  if (!raw) return null;
  const text = raw.trim();
  const json = text.startsWith('{') ? text : Buffer.from(text, 'base64').toString('utf8');
  const sa = JSON.parse(json);
  if (!sa.client_email || !sa.private_key || !sa.project_id) {
    throw new Error('FCM_SERVICE_ACCOUNT must contain client_email, private_key and project_id');
  }
  if (!PROJECT_ID.test(sa.project_id)) throw new Error('FCM_SERVICE_ACCOUNT has an invalid project_id');
  return sa;
}

const b64url = (buf) => Buffer.from(buf).toString('base64url');

/**
 * FCM HTTP v1 sender. [fetchImpl], [endpoint] and [tokenEndpoint] are
 * injectable for tests; the service account's own token_uri is ignored.
 * @returns {{send(token: string, kind: string): Promise<'ok'|'invalid_token'>}}
 */
export function createFcmSender(serviceAccount, { fetchImpl = fetch, endpoint, tokenEndpoint = GOOGLE_TOKEN_URL } = {}) {
  const sa = serviceAccount;
  const tokenUri = tokenEndpoint;
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
    /**
     * [dataOnly]: no notification block, for apps (1.1) that decrypt in the
     * background and show their own notification or ring for a call.
     */
    async send(token, kind, { dataOnly = false } = {}) {
      const title = 'Securely Hello';
      const text = kind === 'request' ? 'You have a new contact request' : 'You have a new message';
      const message = dataOnly
        ? { token, data: { type: kind }, android: { priority: 'high', ttl: '60s' } }
        : {
            token,
            notification: { title, body: text },
            data: { type: kind },
            android: { priority: 'high', collapse_key: 'securelyhello', notification: { tag: 'securelyhello' } },
            apns: {
              headers: { 'apns-collapse-id': 'securelyhello', 'apns-priority': '10' },
              payload: { aps: { sound: 'default' } },
            },
          };
      const res = await fetchImpl(sendUri, {
        method: 'POST',
        headers: { Authorization: `Bearer ${await accessToken()}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ message }),
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
/** Seconds between data pushes to one device. */
export const DATA_PUSH_THROTTLE_SECONDS = 5;

export function createNotifier({ pool, store, hub, sender, log, throttleSeconds = 30 }) {
  async function wakeDevice(userId, deviceId, kind) {
    if (!sender || (await hub.isDeviceConnected(userId, deviceId))) return false;
    const { rows } = await pool.query(
      'SELECT push_token, capabilities FROM devices WHERE id = $1 AND user_id = $2',
      [deviceId, userId],
    );
    const token = rows[0]?.push_token;
    if (!token) return false;
    // 1.1 apps take data pushes: they handle each one themselves (a call
    // must ring), so the throttle is short.
    const dataOnly = (rows[0].capabilities ?? []).includes('data_push');
    if (!(await store.takePushSlot(deviceId, dataOnly ? DATA_PUSH_THROTTLE_SECONDS : throttleSeconds))) return false;
    const result = await sender.send(token, kind, { dataOnly });
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
