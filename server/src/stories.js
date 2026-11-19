// Stories: text, photo and video posts that disappear after 24 hours.
//
// The server never sees a story. Its content is encrypted with a random
// per-story key (photos and videos as ordinary encrypted attachments), and
// that key travels to each audience device in a v3 envelope sealed by the
// poster's Double Ratchet session with that device. This module keeps those
// envelopes until the story expires and enforces who they may go to: the
// poster's contacts (not blocked) and the poster's own devices. Who viewed a
// story, replies and reactions travel end to end as normal messages.
import { withTransaction } from './db.js';
import { validateEnvelope } from './devices.js';
import * as v from './validate.js';
import { HttpError, bad } from './validate.js';

export const STORY_TTL_HOURS = 24;
/** Devices one story can be sealed to (contacts × their devices). */
export const MAX_STORY_KEYS = 5000;
export const MAX_STORY_ATTACHMENTS = 4;
/** A story key envelope carries a key and a little metadata, never media. */
const MAX_KEY_ENVELOPE = 16 * 1024;

const notFound = () => new HttpError(404, 'not_found', 'No such story');

export function registerStoryRoutes(router, { pool, services, config, hub, log }) {
  async function requireApprovedDevice(user) {
    if (!user.deviceId) throw new HttpError(403, 'device_required', 'Register this device first');
    if (!(await services.isDeviceApproved(user.deviceId))) {
      throw new HttpError(403, 'device_pending', 'Approve this device from one of your other devices first');
    }
    return user.deviceId;
  }

  /**
   * {id, keys: [{device_id, envelope}], attachment_ids?: [uuid]}. Every
   * device must belong to a contact or to the poster.
   */
  router.add('POST', '/api/stories', async ({ body, user }) => {
    const senderDevice = await requireApprovedDevice(user);
    v.requireObject(body);
    const id = v.uuid(body.id, 'id');
    const keys = body.keys;
    if (!Array.isArray(keys) || keys.length === 0 || keys.length > MAX_STORY_KEYS) {
      throw bad(`keys must be 1-${MAX_STORY_KEYS} device envelopes`);
    }
    const attachmentIds = body.attachment_ids ?? [];
    if (!Array.isArray(attachmentIds) || attachmentIds.length > MAX_STORY_ATTACHMENTS || !attachmentIds.every(v.isUuid)) {
      throw bad(`attachment_ids must be up to ${MAX_STORY_ATTACHMENTS} attachment ids`);
    }
    const seen = new Set();
    const parsed = keys.map((k, i) => {
      if (k === null || typeof k !== 'object') throw bad(`keys[${i}] must be an object`);
      const deviceId = v.uuid(k.device_id, `keys[${i}].device_id`);
      if (seen.has(deviceId)) throw bad(`keys[${i}].device_id appears twice`);
      seen.add(deviceId);
      if (typeof k.envelope !== 'string' || k.envelope.length > MAX_KEY_ENVELOPE) {
        throw bad(`keys[${i}].envelope is too large`, 'invalid_envelope');
      }
      return { deviceId, envelope: validateEnvelope(k.envelope, { senderId: user.id, senderDevice, recipientDevice: deviceId }) };
    });

    // Who owns each device; the audience is contacts and ourselves.
    const { rows: owners } = await pool.query(
      'SELECT id, user_id FROM devices WHERE id = ANY($1::uuid[]) AND approved_at IS NOT NULL',
      [parsed.map((p) => p.deviceId)],
    );
    const ownerOf = new Map(owners.map((r) => [r.id, r.user_id]));
    const allowed = new Map();
    for (const p of parsed) {
      const owner = ownerOf.get(p.deviceId);
      if (!owner) throw new HttpError(403, 'not_contacts', 'Stories can only go to your contacts');
      if (!allowed.has(owner)) allowed.set(owner, owner === user.id || (await services.areContacts(user.id, owner)));
      if (!allowed.get(owner)) throw new HttpError(403, 'not_contacts', 'Stories can only go to your contacts');
    }

    const story = await withTransaction(pool, async (client) => {
      // One poster at a time, so parallel posts can't each pass the quota.
      await client.query('SELECT pg_advisory_xact_lock(hashtext($1))', [`story:${user.id}`]);
      const { rows: recent } = await client.query(
        "SELECT count(*)::int AS n FROM stories WHERE owner_id = $1 AND created_at > now() - interval '24 hours'",
        [user.id],
      );
      if (recent[0].n >= config.storiesPerDay) {
        throw new HttpError(429, 'story_quota', `You can post ${config.storiesPerDay} stories a day`);
      }
      if (attachmentIds.length > 0) {
        const { rows: mine } = await client.query(
          'SELECT id FROM attachments WHERE id = ANY($1::uuid[]) AND uploader_id = $2 AND expires_at > now()',
          [attachmentIds, user.id],
        );
        if (mine.length !== new Set(attachmentIds.map((a) => a.toLowerCase())).size) {
          throw bad('attachment_ids must be your own current uploads');
        }
      }
      const inserted = await client.query(
        `INSERT INTO stories (id, owner_id, expires_at, attachment_ids)
         VALUES ($1, $2, now() + make_interval(hours => $3), $4)
         ON CONFLICT (id) DO NOTHING
         RETURNING id, created_at, expires_at`,
        [id, user.id, STORY_TTL_HOURS, attachmentIds],
      );
      if (!inserted.rows[0]) throw new HttpError(409, 'story_exists', 'That story was already posted');
      const s = inserted.rows[0];
      // The media goes when the story goes.
      if (attachmentIds.length > 0) {
        await client.query('UPDATE attachments SET expires_at = $2 WHERE id = ANY($1::uuid[])', [
          attachmentIds,
          s.expires_at,
        ]);
      }
      await client.query(
        `INSERT INTO story_keys (story_id, device_id, recipient_id, envelope)
         SELECT $1, d, r, e FROM unnest($2::uuid[], $3::uuid[], $4::text[]) AS t(d, r, e)`,
        [id, parsed.map((p) => p.deviceId), parsed.map((p) => ownerOf.get(p.deviceId)), parsed.map((p) => p.envelope)],
      );
      return s;
    });

    // A nudge to devices that are online; they fetch the key themselves.
    for (const p of parsed) {
      if (p.deviceId === senderDevice) continue;
      hub
        .deliverToDevice(ownerOf.get(p.deviceId), p.deviceId, { type: 'story', story_id: id, owner_id: user.id })
        .catch((err) => log.warn('story nudge failed', { error: err.message }));
    }
    return { status: 201, body: { id: story.id, created_at: story.created_at, expires_at: story.expires_at } };
  });

  /** Story keys for this device, newest first, until they expire. */
  router.add('GET', '/api/stories', async ({ user }) => {
    const deviceId = await requireApprovedDevice(user);
    const { rows } = await pool.query(
      `SELECT s.id AS story_id, s.owner_id, s.created_at, s.expires_at, k.envelope
         FROM story_keys k JOIN stories s ON s.id = k.story_id
        WHERE k.device_id = $1 AND s.expires_at > now()
        ORDER BY s.created_at DESC
        LIMIT 1000`,
      [deviceId],
    );
    return rows;
  });

  /** Deletes your own story early, with its media. */
  router.add('DELETE', '/api/stories/:id', async ({ params, user }) => {
    const id = v.uuid(params.id);
    const { rows } = await pool.query('DELETE FROM stories WHERE id = $1 AND owner_id = $2 RETURNING attachment_ids', [
      id,
      user.id,
    ]);
    if (!rows[0]) throw notFound();
    if (rows[0].attachment_ids.length > 0) {
      // The sweep removes the blobs; nobody can fetch them from now on.
      await pool.query('UPDATE attachments SET expires_at = now() WHERE id = ANY($1::uuid[])', [rows[0].attachment_ids]);
    }
    return { deleted: true };
  });
}

/** Sweep: forgets expired stories (their keys go with them). */
export async function sweepStories(pool) {
  const { rowCount } = await pool.query('DELETE FROM stories WHERE expires_at <= now()');
  return rowCount;
}
