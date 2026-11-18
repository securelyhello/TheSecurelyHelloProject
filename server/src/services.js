// Read paths shared by the HTTP API and the WebSocket hub, with Redis caches
// in front of Postgres. Every write that changes what a cache says calls the
// matching forget*/revoke* here.
import { hashToken } from './security.js';

export class Services {
  /**
   * @param {{pool: import('pg').Pool, store: import('./hotstore.js').HotStore}} deps
   */
  constructor({ pool, store }) {
    this.pool = pool;
    this.store = store;
  }

  // Sessions

  /**
   * Resolves a bearer token to {id, deviceId} or null. deviceId is null until
   * the client registers its device. Cached in Redis for minutes.
   */
  async authenticate(token) {
    const hex = hashToken(token).toString('hex');
    const cached = await this.store.getCachedSession(hex);
    if (cached) return cached;
    const { rows } = await this.pool.query(
      `UPDATE sessions SET last_used_at = now()
        WHERE token_hash = $1 AND expires_at > now()
        RETURNING user_id, device_id, extract(epoch FROM expires_at - now()) AS remaining`,
      [Buffer.from(hex, 'hex')],
    );
    if (!rows[0]) return null;
    await this.store.cacheSession(hex, rows[0].user_id, rows[0].device_id, Number(rows[0].remaining));
    return { id: rows[0].user_id, deviceId: rows[0].device_id };
  }

  /** Drops cached lookups for revoked session hashes (Buffers). */
  async revokeCachedSessions(hashBuffers) {
    await this.store.forgetSessions(hashBuffers.map((b) => Buffer.from(b).toString('hex')));
  }

  // Contacts

  async contactIds(userId) {
    const cached = await this.store.getCachedContacts(userId);
    if (cached) return cached;
    const { rows } = await this.pool.query('SELECT contact_id FROM contacts WHERE owner_id = $1', [userId]);
    const ids = rows.map((r) => r.contact_id);
    await this.store.cacheContacts(userId, ids);
    return ids;
  }

  /** Both directions of the contact edge must exist. */
  async areContacts(a, b) {
    const [ofA, ofB] = await Promise.all([this.contactIds(a), this.contactIds(b)]);
    return ofA.includes(b) && ofB.includes(a);
  }

  /**
   * Whether [a] may send to [b]: contacts, or members of a common group
   * where neither has blocked the other.
   */
  async canReach(a, b) {
    if (await this.areContacts(a, b)) return true;
    const { rows } = await this.pool.query(
      `SELECT 1 FROM group_members x JOIN group_members y ON y.group_id = x.group_id
        WHERE x.user_id = $1 AND y.user_id = $2
          AND NOT EXISTS (SELECT 1 FROM blocks
                           WHERE (blocker_id = $1 AND blocked_id = $2) OR (blocker_id = $2 AND blocked_id = $1))
        LIMIT 1`,
      [a, b],
    );
    return rows.length > 0;
  }

  /** Call after any change to the contact edges of these users. */
  async contactsChanged(...userIds) {
    await this.store.forgetContacts(...userIds);
  }

  // Devices

  /** Ids of [userId]'s registered devices (oldest first). */
  async deviceIds(userId) {
    const cached = await this.store.getCachedDevices(userId);
    if (cached) return cached;
    const { rows } = await this.pool.query(
      'SELECT id FROM devices WHERE user_id = $1 AND approved_at IS NOT NULL ORDER BY created_at, id',
      [userId],
    );
    const ids = rows.map((r) => r.id);
    await this.store.cacheDevices(userId, ids);
    return ids;
  }

  async isDeviceApproved(deviceId) {
    const { rows } = await this.pool.query('SELECT approved_at FROM devices WHERE id = $1', [deviceId]);
    return rows[0]?.approved_at != null;
  }

  async devicesChanged(...userIds) {
    await this.store.forgetDevices(...userIds);
  }

  // Presence

  async presence(ids) {
    return this.store.presence(ids);
  }
}
