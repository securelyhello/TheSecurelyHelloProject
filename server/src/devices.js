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
export function registerDeviceRoutes(router, { pool, hub, store, services, limits, log, notifier }) {
  const tooMany = () => new HttpError(429, 'rate_limited', 'Too many requests, slow down');
  async function limit(name, key) {
    if (!(await limits.take(name, key))) throw tooMany();
  }

  /** Session must have registered a device for device-scoped routes. */
  function requireDevice(user) {
    if (!user.deviceId) throw new HttpError(409, 'no_device', 'Register this device first');
    return user.deviceId;
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
        if (keysChanged) await client.query('DELETE FROM one_time_prekeys WHERE device_id = $1', [deviceId]);
        await client.query(
          `UPDATE devices SET name = COALESCE(NULLIF($2, ''), name), signing_public_key = $3, identity_public_key = $4,
                  signed_prekey_id = $5, signed_prekey = $6, signed_prekey_signature = $7,
                  updated_at = now(), last_seen_at = now()
            WHERE id = $1`,
          [deviceId, name, signingKey, identityKey, spk.id, spk.key, spk.signature],
        );
      } else {
        const { rows: count } = await client.query('SELECT count(*)::int AS n FROM devices WHERE user_id = $1', [
          user.id,
        ]);
        if (count[0].n >= MAX_DEVICES_PER_USER) {
          throw new HttpError(409, 'too_many_devices', `Remove a device first (limit ${MAX_DEVICES_PER_USER})`);
        }
        const { rows } = await client.query(
          `INSERT INTO devices (user_id, name, signing_public_key, identity_public_key,
                                signed_prekey_id, signed_prekey, signed_prekey_signature)
           VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING id`,
          [user.id, name, signingKey, identityKey, spk.id, spk.key, spk.signature],
        );
        deviceId = rows[0].id;
        created = true;
      }
      await insertPreKeys(client, deviceId, otpks);
      await client.query('UPDATE sessions SET device_id = $2 WHERE token_hash = $1', [hashToken(token), deviceId]);
      return { deviceId, created, keysChanged, remaining: await prekeysRemaining(deviceId, client) };
    });

    // The cached session still says "no device".
    await services.revokeCachedSessions([hashToken(token)]);
    if (result.created || result.keysChanged) await announceDevices(user.id);
    hub.bindDevice(user.id, token, result.deviceId);
    return {
      status: result.created ? 201 : 200,
      body: { device_id: result.deviceId, prekeys_remaining: result.remaining },
    };
  });

  router.add('GET', '/api/devices/current', async ({ user }) => {
    const deviceId = requireDevice(user);
    return { device_id: deviceId, prekeys_remaining: await prekeysRemaining(deviceId) };
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
    return rows.map((r) => ({ ...deviceJson(r, { withName: true }), current: r.id === user.deviceId }));
  });

  router.add('PATCH', '/api/devices/current', async ({ body, user }) => {
    const deviceId = requireDevice(user);
    v.requireObject(body);
    await pool.query('UPDATE devices SET name = $2, updated_at = now() WHERE id = $1', [deviceId, deviceName(body.name)]);
  });

  /** Unlinks a device: its sessions end and its queue is dropped. */
  router.add('DELETE', '/api/devices/:id', async ({ params, user }) => {
    const id = v.uuid(params.id);
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
    const { rows } = await pool.query('SELECT * FROM devices WHERE user_id = $1 ORDER BY created_at, id', [target]);
    return rows.map((r) => deviceJson(r, { withName: target === user.id }));
  });

  /**
   * Claims one prekey bundle per requested device of [id] (a contact or
   * yourself). Each one-time prekey is handed out once.
   */
  router.add('POST', '/api/users/:id/prekey-bundles', async ({ params, body, user }) => {
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
        const { rows } = await client.query('SELECT * FROM devices WHERE id = $1 AND user_id = $2', [
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
    const senderDevice = requireDevice(user);
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

    const parsed = body.messages.map((m, i) => {
      if (m === null || typeof m !== 'object') throw bad(`messages[${i}] must be an object`);
      const deviceId = v.uuid(m.device_id, `messages[${i}].device_id`);
      if (!known.has(deviceId)) throw bad(`messages[${i}].device_id is not in known_devices`);
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
      if (!msg) throw new HttpError(429, 'recipient_queue_full', 'The recipient has too many undelivered messages');
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
    const deviceId = requireDevice(user);
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
