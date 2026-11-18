// Devices, prekeys and the per-device ciphertext relay queue (protocol v3).
//
// Every client device registers an identity (Ed25519 signing key + X25519
// key), a signed prekey and one-time prekeys. Senders fetch a prekey bundle
// per device, run X3DH and keep a Double Ratchet per device pair, so the
// server only ever moves opaque envelopes addressed to one device each.
import { createPublicKey, verify as verifySignature } from 'node:crypto';

import { withTransaction } from './db.js';
import { hashToken } from './security.js';
import * as v from './validate.js';
import { HttpError, bad } from './validate.js';

export const MAX_DEVICES_PER_USER = 10;
export const MAX_ONE_TIME_PREKEYS = 200;
const ED25519_SPKI_PREFIX = Buffer.from('302a300506032b6570032100', 'hex');
const SIG_RE = /^[A-Za-z0-9+/]{86}==$/;
const SPK_LABEL = Buffer.from('securelyhello-spk-v1', 'utf8');

/** The bytes a signed prekey signature covers (the Dart client signs the same). */
export function signedPreKeyMessage(id, keyB64) {
  const idBuf = Buffer.alloc(4);
  idBuf.writeUInt32BE(id);
  return Buffer.concat([SPK_LABEL, idBuf, Buffer.from(keyB64, 'base64')]);
}

function ed25519Verify(publicKeyB64, message, signatureB64) {
  try {
    const key = createPublicKey({
      key: Buffer.concat([ED25519_SPKI_PREFIX, Buffer.from(publicKeyB64, 'base64')]),
      format: 'der',
      type: 'spki',
    });
    return verifySignature(null, message, key, Buffer.from(signatureB64, 'base64'));
  } catch {
    return false;
  }
}

function keyId(value, field) {
  if (!Number.isInteger(value) || value < 0 || value > 0x7fffffff) throw bad(`${field} must be a non-negative integer`);
  return value;
}

function signedPreKey(raw, signingKey) {
  if (raw === null || typeof raw !== 'object') throw bad('signed_prekey is required');
  const id = keyId(raw.id, 'signed_prekey.id');
  const key = v.publicKey(raw.key, 'signed_prekey.key');
  if (typeof raw.signature !== 'string' || !SIG_RE.test(raw.signature)) {
    throw bad('signed_prekey.signature must be a base64 Ed25519 signature');
  }
  if (!ed25519Verify(signingKey, signedPreKeyMessage(id, key), raw.signature)) {
    throw bad('signed_prekey.signature does not verify', 'bad_signature');
  }
  return { id, key, signature: raw.signature };
}

function oneTimePreKeys(raw) {
  if (raw === undefined) return [];
  if (!Array.isArray(raw) || raw.length > 100) throw bad('one_time_prekeys must be an array of at most 100 keys');
  const seen = new Set();
  return raw.map((k, i) => {
    if (k === null || typeof k !== 'object') throw bad(`one_time_prekeys[${i}] must be an object`);
    const id = keyId(k.id, `one_time_prekeys[${i}].id`);
    if (seen.has(id)) throw bad('one_time_prekeys ids must be unique');
    seen.add(id);
    return { id, key: v.publicKey(k.key, `one_time_prekeys[${i}].key`) };
  });
}

function deviceName(raw) {
  if (raw === undefined || raw === null) return '';
  if (typeof raw !== 'string') throw bad('name must be a string');
  return raw.trim().replace(/[\u0000-\u001f\u007f]/g, '').slice(0, 64);
}

const deviceJson = (row, { withName }) => ({
  device_id: row.id,
  signing_public_key: row.signing_public_key,
  identity_public_key: row.identity_public_key,
  created_at: row.created_at,
  ...(withName ? { name: row.name, last_seen_at: row.last_seen_at } : {}),
});

/**
 * @param {import('./http.js').Router} router
 */
/** What an approving device signs: the new device's identity, for one account. */
/**
 * What a client signs, with its device's CURRENT signing key, to take its
 * device back in a new session or to change that device's keys. Binding the
 * session (SHA-256 of its token) stops the signature being reused elsewhere.
 */
export function deviceProofMessage(userId, deviceId, tokenHashHex, signingKey, identityKey) {
  return Buffer.from(`securelyhello-device-proof-v1|${userId}|${deviceId}|${tokenHashHex}|${signingKey}|${identityKey}`);
}

export function approvalMessage(userId, deviceId, signingKey, identityKey) {
  return Buffer.from(`securelyhello-approve-v1|${userId}|${deviceId}|${signingKey}|${identityKey}`, 'utf8');
}

export function registerDeviceRoutes(router, { pool, hub, store, services, limits, log, notifier, codes, mailer, twoFactor }) {
  const tooMany = () => new HttpError(429, 'rate_limited', 'Too many requests, slow down');
  async function limit(name, key) {
    if (!(await limits.take(name, key))) throw tooMany();
  }

  /** Session must have registered a device for device-scoped routes. */
  function requireDevice(user) {
    if (!user.deviceId) throw new HttpError(409, 'no_device', 'Register this device first');
    return user.deviceId;
  }

  /** ...and that device must be approved to send or receive messages. */
  async function requireApprovedDevice(user) {
    const id = requireDevice(user);
    if (!(await services.isDeviceApproved(id))) {
      throw new HttpError(403, 'device_pending', 'Approve this device from one of your other devices first');
    }
    return id;
  }

  async function prekeysRemaining(deviceId, client = pool) {
    const { rows } = await client.query('SELECT count(*)::int AS n FROM one_time_prekeys WHERE device_id = $1', [
      deviceId,
    ]);
    return rows[0].n;
  }

  async function insertPreKeys(client, deviceId, keys) {
    if (!keys.length) return;
    const have = await prekeysRemaining(deviceId, client);
    if (have + keys.length > MAX_ONE_TIME_PREKEYS) {
      throw bad(`A device holds at most ${MAX_ONE_TIME_PREKEYS} one-time prekeys`, 'too_many_prekeys');
    }
    await client.query(
      `INSERT INTO one_time_prekeys (device_id, key_id, public_key)
       SELECT $1, k.id, k.key FROM jsonb_to_recordset($2::jsonb) AS k(id int, key text)
       ON CONFLICT (device_id, key_id) DO UPDATE SET public_key = EXCLUDED.public_key`,
      [deviceId, JSON.stringify(keys)],
    );
  }

  /** Tells the user's contacts and their other devices that the device list changed. */
  async function announceDevices(userId) {
    await services.devicesChanged(userId);
    const frame = { type: 'devices_changed', user_id: userId };
    for (const id of await services.contactIds(userId)) hub.sendTo(id, frame);
    hub.sendTo(userId, frame);
  }

  // ---------------------------------------------------------------------------
  // Registration
  // ---------------------------------------------------------------------------

  /**
   * Registers this session's device, or updates it. A client that kept its
   * device id (sign out and back in on the same install) passes it to keep
   * its identity; otherwise a new device is created.
   */
  router.add('PUT', '/api/devices/current', async ({ body, user, token }) => {
    v.requireObject(body);
    const signingKey = v.publicKey(body.signing_public_key, 'signing_public_key');
    const identityKey = v.publicKey(body.identity_public_key, 'identity_public_key');
    const spk = signedPreKey(body.signed_prekey, signingKey);
    const otpks = oneTimePreKeys(body.one_time_prekeys);
    const name = deviceName(body.name);
    const wanted = body.device_id == null ? null : v.uuid(body.device_id, 'device_id');

    const result = await withTransaction(pool, async (client) => {
      await client.query('SELECT pg_advisory_xact_lock(hashtext($1))', [`devices:${user.id}`]);
      let deviceId = user.deviceId ?? wanted;
      let existing = null;
      if (deviceId) {
        const { rows } = await client.query('SELECT * FROM devices WHERE id = $1 AND user_id = $2 FOR UPDATE', [
          deviceId,
          user.id,
        ]);
        existing = rows[0] ?? null;
        if (!existing && user.deviceId) throw new HttpError(410, 'device_removed', 'This device was removed');
      }
      let created = false;
      let keysChanged = false;
      if (existing) {
        keysChanged =
          existing.signing_public_key !== signingKey || existing.identity_public_key !== identityKey;
        // Taking a device back in a new session, or changing its keys, needs
        // its current signing key: knowing the password or holding a token
        // is not proof of being that device.
        if (!user.deviceId || keysChanged) {
          const proof = typeof body.proof === 'string' && SIG_RE.test(body.proof) ? body.proof : null;
          const message = deviceProofMessage(
            user.id, deviceId, hashToken(token).toString('hex'), signingKey, identityKey,
          );
          if (!proof || !ed25519Verify(existing.signing_public_key, message, proof)) {
            throw new HttpError(403, 'device_proof_required', "This device's key is needed to use it again");
          }
        }
        if (keysChanged) await client.query('DELETE FROM one_time_prekeys WHERE device_id = $1', [deviceId]);
        await client.query(
          `UPDATE devices SET name = COALESCE(NULLIF($2, ''), name), signing_public_key = $3, identity_public_key = $4,
                  signed_prekey_id = $5, signed_prekey = $6, signed_prekey_signature = $7,
                  updated_at = now(), last_seen_at = now()
            WHERE id = $1`,
          [deviceId, name, signingKey, identityKey, spk.id, spk.key, spk.signature],
        );
        // A key change was signed by the old key, so the device keeps its
        // approval; contacts are told its keys changed.
      } else {
        const { rows: count } = await client.query('SELECT count(*)::int AS n FROM devices WHERE user_id = $1', [
          user.id,
        ]);
        if (count[0].n >= MAX_DEVICES_PER_USER) {
          throw new HttpError(409, 'too_many_devices', `Remove a device first (limit ${MAX_DEVICES_PER_USER})`);
        }
        // Only an account's very first device is trusted on its own; any
        // later one waits for approval by an existing device or recovery.
        const { rows: first } = await client.query(
          `UPDATE users u SET first_device_at = COALESCE(u.first_device_at, now())
             FROM (SELECT first_device_at AS before FROM users WHERE id = $1) old
            WHERE u.id = $1 RETURNING old.before`,
          [user.id],
        );
        const autoApprove = first[0].before == null;
        const { rows } = await client.query(
          `INSERT INTO devices (user_id, name, signing_public_key, identity_public_key,
                                signed_prekey_id, signed_prekey, signed_prekey_signature, approved_at)
           VALUES ($1, $2, $3, $4, $5, $6, $7, CASE WHEN $8 THEN now() END) RETURNING id`,
          [user.id, name, signingKey, identityKey, spk.id, spk.key, spk.signature, autoApprove],
        );
        deviceId = rows[0].id;
        created = true;
      }
      await insertPreKeys(client, deviceId, otpks);
      await client.query('UPDATE sessions SET device_id = $2 WHERE token_hash = $1', [hashToken(token), deviceId]);
      const { rows: st } = await client.query('SELECT approved_at, name FROM devices WHERE id = $1', [deviceId]);
      return {
        deviceId,
        created,
        keysChanged,
        approved: st[0].approved_at != null,
        name: st[0].name,
        remaining: await prekeysRemaining(deviceId, client),
      };
    });

    // The cached session still says "no device".
    await services.revokeCachedSessions([hashToken(token)]);
    if (result.approved && (result.created || result.keysChanged)) await announceDevices(user.id);
    hub.bindDevice(user.id, token, result.deviceId, result.approved);
    if (!result.approved && (result.created || result.keysChanged)) {
      // Sign-in alert: every approved device is asked to approve or remove it.
      hub.sendTo(user.id, { type: 'device_pending', device_id: result.deviceId, name: result.name });
      notifier?.wakeUser(user.id, 'device').catch((err) => log.warn('push failed', { error: err.message }));
    }
    return {
      status: result.created ? 201 : 200,
      body: { device_id: result.deviceId, approved: result.approved, prekeys_remaining: result.remaining },
    };
  });

  router.add('GET', '/api/devices/current', async ({ user }) => {
    const deviceId = requireDevice(user);
    return {
      device_id: deviceId,
      approved: await services.isDeviceApproved(deviceId),
      prekeys_remaining: await prekeysRemaining(deviceId),
    };
  });

  /**
   * An approved device approves a pending one of the same account. The body
   * carries an Ed25519 signature, by the approving device's own key, over
   * approvalMessage(): a session token alone can't approve anything.
   */
  router.add('POST', '/api/devices/:id/approve', async ({ params, body, user }) => {
    const approver = await requireApprovedDevice(user);
    const target = v.uuid(params.id);
    v.requireObject(body);
    if (typeof body.signature !== 'string' || !SIG_RE.test(body.signature)) throw bad('signature is required');
    const { rows } = await pool.query(
      `SELECT d.*, a.signing_public_key AS approver_key FROM devices d, devices a
        WHERE d.id = $1 AND d.user_id = $2 AND a.id = $3`,
      [target, user.id, approver],
    );
    const d = rows[0];
    if (!d) throw new HttpError(404, 'not_found', 'No such device');
    if (d.approved_at) return { device_id: target, approved: true };
    const message = approvalMessage(user.id, target, d.signing_public_key, d.identity_public_key);
    if (!ed25519Verify(d.approver_key, message, body.signature)) {
      throw bad('signature does not verify', 'bad_signature');
    }
    await pool.query(
      'UPDATE devices SET approved_at = now(), approved_by = $2, approval_signature = $3 WHERE id = $1',
      [target, approver, body.signature],
    );
    hub.setDeviceApproved(user.id, target);
    hub.sendToDevice(user.id, target, { type: 'device_approved' });
    await announceDevices(user.id);
    return { device_id: target, approved: true };
  });

  /**
   * Lost every other device? A pending device can recover the account with
   * an e-mailed code. Doing so removes all other devices (their sessions end),
   * so contacts see the safety number change, as with any account recovery.
   */
  router.add('POST', '/api/devices/current/recover', async ({ user }) => {
    const deviceId = requireDevice(user);
    if (await services.isDeviceApproved(deviceId)) return { status: 200, body: { approved: true } };
    if (!mailer?.enabled) throw new HttpError(503, 'email_unavailable', 'E-mail is not configured on this server');
    if (!(await limits.take('emailSend', `device:${user.id}`))) {
      throw new HttpError(429, 'rate_limited', 'Too many requests, slow down');
    }
    const { rows } = await pool.query('SELECT email FROM users WHERE id = $1', [user.id]);
    await codes.issueCode(user.id, rows[0].email, 'device');
    return { status: 202, body: { sent: true } };
  });

  router.add('POST', '/api/devices/current/recover/confirm', async ({ body, user }) => {
    const deviceId = requireDevice(user);
    v.requireObject(body);
    if (!(await codes.consumeCode(user.id, 'device', body.code, { keep: true }))) {
      throw new HttpError(400, 'invalid_code', 'That code is wrong or has expired');
    }
    await twoFactor.require(user.id, body.otp);
    if (!(await codes.consumeCode(user.id, 'device', body.code))) {
      throw new HttpError(400, 'invalid_code', 'That code is wrong or has expired');
    }
    const removed = await withTransaction(pool, async (client) => {
      const others = await client.query('SELECT id FROM devices WHERE user_id = $1 AND id <> $2', [user.id, deviceId]);
      const sessions = await client.query(
        'SELECT token_hash FROM sessions WHERE user_id = $1 AND device_id IS NOT NULL AND device_id <> $2',
        [user.id, deviceId],
      );
      await client.query('DELETE FROM devices WHERE user_id = $1 AND id <> $2', [user.id, deviceId]);
      await client.query(
        'UPDATE devices SET approved_at = now(), approved_by = NULL, approval_signature = NULL WHERE id = $1',
        [deviceId],
      );
      return { devices: others.rows.map((r) => r.id), sessions: sessions.rows.map((r) => r.token_hash) };
    });
    await services.revokeCachedSessions(removed.sessions);
    for (const d of removed.devices) {
      await store.relayPurgeDevice(d);
      hub.disconnectDevice(user.id, d, 4004, 'device removed');
    }
    hub.setDeviceApproved(user.id, deviceId);
    await announceDevices(user.id);
    return { approved: true, removed_devices: removed.devices.length };
  });

  router.add('POST', '/api/devices/current/prekeys', async ({ body, user }) => {
    const deviceId = requireDevice(user);
    v.requireObject(body);
    const keys = oneTimePreKeys(body.one_time_prekeys);
    const remaining = await withTransaction(pool, async (client) => {
      await insertPreKeys(client, deviceId, keys);
      return prekeysRemaining(deviceId, client);
    });
    return { prekeys_remaining: remaining };
  });

  router.add('PUT', '/api/devices/current/signed-prekey', async ({ body, user }) => {
    const deviceId = requireDevice(user);
    v.requireObject(body);
    const { rows } = await pool.query('SELECT signing_public_key FROM devices WHERE id = $1', [deviceId]);
    if (!rows[0]) throw new HttpError(410, 'device_removed', 'This device was removed');
    const spk = signedPreKey(body, rows[0].signing_public_key);
    await pool.query(
      `UPDATE devices SET signed_prekey_id = $2, signed_prekey = $3, signed_prekey_signature = $4, updated_at = now()
        WHERE id = $1`,
      [deviceId, spk.id, spk.key, spk.signature],
    );
  });

  /** Our own devices, with names (for the "Linked devices" screen). */
  router.add('GET', '/api/devices', async ({ user }) => {
    const { rows } = await pool.query('SELECT * FROM devices WHERE user_id = $1 ORDER BY created_at, id', [user.id]);
    return rows.map((r) => ({
      ...deviceJson(r, { withName: true }),
      current: r.id === user.deviceId,
      approved: r.approved_at != null,
      push_enabled: r.push_token != null,
    }));
  });

  /**
   * Registers this device's push token (FCM). The token is moved here if
   * another device had it (reinstall). Pushes only ever say "something is
   * waiting"; see push.js.
   */
  router.add('PUT', '/api/devices/current/push', async ({ body, user }) => {
    const deviceId = requireDevice(user);
    v.requireObject(body);
    if (body.platform !== 'fcm') throw bad("platform must be 'fcm'");
    const token = v.string(body.token, 'token', { min: 16, max: 4096 });
    await withTransaction(pool, async (client) => {
      await client.query('UPDATE devices SET push_token = NULL, push_platform = NULL WHERE push_token = $1 AND id <> $2', [
        token,
        deviceId,
      ]);
      await client.query("UPDATE devices SET push_token = $2, push_platform = 'fcm' WHERE id = $1", [deviceId, token]);
    });
    return { push_enabled: true, push_available: notifier?.enabled ?? false };
  });

  router.add('DELETE', '/api/devices/current/push', async ({ user }) => {
    const deviceId = requireDevice(user);
    await pool.query('UPDATE devices SET push_token = NULL, push_platform = NULL WHERE id = $1', [deviceId]);
  });

  router.add('PATCH', '/api/devices/current', async ({ body, user }) => {
    const deviceId = requireDevice(user);
    v.requireObject(body);
    await pool.query('UPDATE devices SET name = $2, updated_at = now() WHERE id = $1', [deviceId, deviceName(body.name)]);
  });

  /** Unlinks a device: its sessions end and its queue is dropped. */
  router.add('DELETE', '/api/devices/:id', async ({ params, user }) => {
    const id = v.uuid(params.id);
    // A device waiting for approval may remove itself, not the others.
    if (id !== user.deviceId) await requireApprovedDevice(user);
    const revoked = await withTransaction(pool, async (client) => {
      const sessions = await client.query('SELECT token_hash FROM sessions WHERE device_id = $1', [id]);
      const { rowCount } = await client.query('DELETE FROM devices WHERE id = $1 AND user_id = $2', [id, user.id]);
      if (!rowCount) throw new HttpError(404, 'not_found', 'No such device');
      // ON DELETE CASCADE removed its sessions.
      return sessions.rows.map((r) => r.token_hash);
    });
    await services.revokeCachedSessions(revoked);
    await store.relayPurgeDevice(id);
    hub.disconnectDevice(user.id, id, 4004, 'device removed');
    await announceDevices(user.id);
  });

  // ---------------------------------------------------------------------------
  // Directory of devices and prekey bundles
  // ---------------------------------------------------------------------------

  /** Public device keys of any user (names only for yourself). */
  router.add('GET', '/api/users/:id/devices', async ({ params, user }) => {
    const target = v.uuid(params.id);
    const { rows } = await pool.query(
      'SELECT * FROM devices WHERE user_id = $1 AND approved_at IS NOT NULL ORDER BY created_at, id',
      [target],
    );
    return rows.map((r) => deviceJson(r, { withName: target === user.id }));
  });

  /**
   * Claims one prekey bundle per requested device of [id] (a contact or
   * yourself). Each one-time prekey is handed out once.
   */
  router.add('POST', '/api/users/:id/prekey-bundles', async ({ params, body, user }) => {
    await requireApprovedDevice(user);
    const target = v.uuid(params.id);
    v.requireObject(body);
    const ids = body.device_ids;
    if (!Array.isArray(ids) || ids.length === 0 || ids.length > MAX_DEVICES_PER_USER || !ids.every(v.isUuid)) {
      throw bad(`device_ids must be 1-${MAX_DEVICES_PER_USER} UUIDs`);
    }
    if (target !== user.id && !(await services.areContacts(user.id, target))) {
      throw new HttpError(403, 'not_contacts', 'You can only start sessions with accepted contacts');
    }
    await limit('prekeyClaim', user.id);
    const bundles = await withTransaction(pool, async (client) => {
      const out = [];
      for (const deviceId of ids.map((x) => x.toLowerCase())) {
        const { rows } = await client.query('SELECT * FROM devices WHERE id = $1 AND user_id = $2 AND approved_at IS NOT NULL', [
          deviceId,
          target,
        ]);
        if (!rows[0]) continue;
        const d = rows[0];
        const otpk = await client.query(
          `DELETE FROM one_time_prekeys
            WHERE (device_id, key_id) = (
              SELECT device_id, key_id FROM one_time_prekeys WHERE device_id = $1
               ORDER BY key_id LIMIT 1 FOR UPDATE SKIP LOCKED)
            RETURNING key_id, public_key`,
          [deviceId],
        );
        out.push({
          ...deviceJson(d, { withName: false }),
          signed_prekey: { id: d.signed_prekey_id, key: d.signed_prekey, signature: d.signed_prekey_signature },
          one_time_prekey: otpk.rows[0] ? { id: otpk.rows[0].key_id, key: otpk.rows[0].public_key } : null,
        });
      }
      return out;
    });
    // Tell devices running low so they top up.
    for (const b of bundles) {
      if (b.one_time_prekey) {
        const left = await prekeysRemaining(b.device_id);
        if (left < 20) hub.sendToDevice(target, b.device_id, { type: 'prekeys_low', remaining: left });
      }
    }
    return bundles;
  });

  // ---------------------------------------------------------------------------
  // Relay queue (ciphertext only, one queue per device, Redis with a TTL)
  // ---------------------------------------------------------------------------

  const ENVELOPE_KEYS = 'c,h,id,rd,s,sd,t,v';
  const B64_RE = /^[A-Za-z0-9+/]+={0,2}$/;

  /**
   * A v3 envelope: {"v":3,"id","s","sd","rd","t","h","c"}. The server cannot
   * read `h` (ratchet header) or `c` (ciphertext); it checks the outer shape
   * so a buggy client can't park plaintext or spoof the sender here.
   */
  function validateEnvelope(raw, { senderId, senderDevice, recipientDevice }) {
    const text = v.string(raw, 'envelope', { min: 2, max: 128 * 1024 });
    let env;
    try {
      env = JSON.parse(text);
    } catch {
      throw bad('envelope must be JSON', 'invalid_envelope');
    }
    const keys = env && typeof env === 'object' && !Array.isArray(env) ? Object.keys(env).sort().join(',') : '';
    if (
      keys !== ENVELOPE_KEYS ||
      env.v !== 3 ||
      env.s !== senderId ||
      env.sd !== senderDevice ||
      env.rd !== recipientDevice ||
      typeof env.id !== 'string' ||
      env.id.length < 1 ||
      env.id.length > 64 ||
      !Number.isSafeInteger(env.t) ||
      typeof env.h !== 'string' ||
      env.h.length < 2 ||
      env.h.length > 4096 ||
      typeof env.c !== 'string' ||
      env.c.length < 32 ||
      !B64_RE.test(env.c)
    ) {
      throw bad('envelope is not a valid v3 envelope from this device', 'invalid_envelope');
    }
    return text;
  }

  /**
   * Queues one logical message for every device of [recipient_id]:
   *   {recipient_id, known_devices:[…], messages:[{device_id, envelope}]}
   * `known_devices` is the sender's view of the recipient's devices (for
   * yourself: your other devices). If it is stale the server answers 409
   * `devices_changed` with the current list, so no device is silently
   * skipped. `messages` may cover a subset (the rest went over WebRTC).
   */
  router.add('POST', '/api/relay', async ({ body, user }) => {
    const senderDevice = await requireApprovedDevice(user);
    await limit('relay', user.id);
    v.requireObject(body);
    const recipientId = v.uuid(body.recipient_id, 'recipient_id');
    if (!Array.isArray(body.known_devices) || body.known_devices.length > MAX_DEVICES_PER_USER || !body.known_devices.every(v.isUuid)) {
      throw bad('known_devices must be an array of device UUIDs');
    }
    if (!Array.isArray(body.messages) || body.messages.length > MAX_DEVICES_PER_USER) {
      throw bad(`messages must be an array of at most ${MAX_DEVICES_PER_USER}`);
    }
    if (recipientId !== user.id && !(await services.areContacts(user.id, recipientId))) {
      throw new HttpError(403, 'not_contacts', 'You can only message accepted contacts');
    }

    let actual = await services.deviceIds(recipientId);
    if (recipientId === user.id) actual = actual.filter((d) => d !== senderDevice);
    const known = new Set(body.known_devices.map((d) => d.toLowerCase()));
    if (known.size !== actual.length || actual.some((d) => !known.has(d))) {
      return { status: 409, body: { error: 'devices_changed', message: 'The recipient\'s devices changed', devices: actual } };
    }

    const seen = new Set();
    const parsed = body.messages.map((m, i) => {
      if (m === null || typeof m !== 'object') throw bad(`messages[${i}] must be an object`);
      const deviceId = v.uuid(m.device_id, `messages[${i}].device_id`);
      if (!known.has(deviceId)) throw bad(`messages[${i}].device_id is not in known_devices`);
      if (seen.has(deviceId)) throw bad(`messages[${i}].device_id appears twice`);
      seen.add(deviceId);
      return {
        deviceId,
        envelope: validateEnvelope(m.envelope, { senderId: user.id, senderDevice, recipientDevice: deviceId }),
      };
    });

    const out = [];
    for (const m of parsed) {
      const msg = await store.relayEnqueue({
        senderId: user.id,
        senderDevice,
        recipientId,
        recipientDevice: m.deviceId,
        envelope: m.envelope,
      });
      if (msg.full === 'recipient') {
        throw new HttpError(429, 'recipient_queue_full', 'The recipient has too many undelivered messages');
      }
      if (msg.full === 'sender') {
        throw new HttpError(429, 'relay_budget', 'Too much of what you sent is still undelivered. Try again later.');
      }
      const pushed =
        hub.sendToDevice(recipientId, m.deviceId, {
          type: 'relay',
          message: {
            id: msg.id,
            sender_id: user.id,
            sender_device: senderDevice,
            envelope: m.envelope,
            created_at: msg.created_at,
          },
        }) > 0;
      if (!pushed) notifier?.wake(recipientId, m.deviceId, 'message').catch((err) => log.warn('push failed', { error: err.message }));
      out.push({ device_id: m.deviceId, id: msg.id, pushed });
    }
    return { status: 201, body: { messages: out } };
  });

  router.add('GET', '/api/relay', async ({ query, user }) => {
    const deviceId = await requireApprovedDevice(user);
    const n = Math.min(Math.max(Number.parseInt(query.get('limit') ?? '100', 10) || 100, 1), 200);
    return store.relayFetch(deviceId, n);
  });

  router.add('POST', '/api/relay/ack', async ({ body, user }) => {
    const deviceId = requireDevice(user);
    v.requireObject(body);
    const ids = body.ids;
    if (!Array.isArray(ids) || ids.length === 0 || ids.length > 200 || !ids.every(v.isUuid)) {
      throw bad('ids must be 1-200 UUIDs');
    }
    return { deleted: await store.relayAck(deviceId, ids.map((id) => id.toLowerCase())) };
  });

  router.add('DELETE', '/api/relay/:id', async ({ params, user }) => {
    await store.relayAck(requireDevice(user), [v.uuid(params.id)]);
  });
}
