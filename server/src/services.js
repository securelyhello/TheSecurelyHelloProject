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
   * Resolves a bearer token to {id, deviceId} or null: null for a missing,
   * malformed, expired or unknown token, or a suspended account. deviceId is
   * null until the client registers its device. Cached in Redis for minutes;
   * revokeCachedSessions() and suspensionChanged() make cached entries stale at once,
   * including ones written by a lookup that raced the revocation.
   */
  async authenticate(token) {
    if (typeof token !== 'string' || token.length === 0) return null;
    const hex = hashToken(token).toString('hex');
    const cached = await this.store.getCachedSession(hex);
    if (cached) return cached;
    // Taken before the read: a revocation after this instant wins.
    const lookedUpAt = await this.store.clockMicros();
    const { rows } = await this.pool.query(
      `UPDATE sessions s SET last_used_at = now()
         FROM users u
        WHERE s.token_hash = $1 AND s.expires_at > now() AND u.id = s.user_id AND u.suspended_at IS NULL
        RETURNING s.user_id, s.device_id, extract(epoch FROM s.expires_at - now()) AS remaining`,
      [Buffer.from(hex, 'hex')],
    );
    if (!rows[0]) return null;
    await this.store.cacheSession(hex, rows[0].user_id, rows[0].device_id, Number(rows[0].remaining), lookedUpAt);
    return { id: rows[0].user_id, deviceId: rows[0].device_id };
  }

  /**
   * Call after deleting sessions of [userId] (or changing what they resolve
   * to): drops the cached lookups for [hashBuffers] and marks every session
   * of the user cached so far as stale.
   */
  async revokeCachedSessions(userId, hashBuffers) {
    if (typeof userId !== 'string') throw new TypeError('revokeCachedSessions needs the user id');
    await this.store.markSessionsRevoked(userId);
    await this.store.forgetSessions(hashBuffers.map((b) => Buffer.from(b).toString('hex')));
  }

  /** The account was suspended (sessions already deleted) or unsuspended. */
  async suspensionChanged(userId, suspended) {
    if (suspended) await this.store.markSuspended(userId);
    else await this.store.clearSuspended(userId);
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
