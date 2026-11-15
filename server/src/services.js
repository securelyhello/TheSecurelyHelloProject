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

  // ---------------------------------------------------------------------------
  // Sessions
  // ---------------------------------------------------------------------------

  /**
   * Resolves a bearer token to {id} or null. Cached in Redis for minutes.
   *
   * Each cache entry carries the time its DB lookup *began*. Revoking all of
   * a user's sessions sets a "revoked at" marker, and entries from lookups
   * that began at or before it are ignored. That closes the race where a
   * request reads the session row just before a reset deletes it and writes
   * the cache entry just after the reset cleared the cache.
   */
  async authenticate(token) {
    const hex = hashToken(token).toString('hex');
    const cached = await this.store.getCachedSession(hex);
    if (cached) {
      const revokedAt = await this.store.sessionsRevokedAt(cached.userId);
      if (revokedAt === null || cached.at > revokedAt) return { id: cached.userId };
    }
    const startedAt = Date.now();
    const { rows } = await this.pool.query(
      `UPDATE sessions SET last_used_at = now()
        WHERE token_hash = $1 AND expires_at > now()
        RETURNING user_id, extract(epoch FROM expires_at - now()) AS remaining`,
      [Buffer.from(hex, 'hex')],
    );
    if (!rows[0]) return null;
    await this.store.cacheSession(hex, rows[0].user_id, Number(rows[0].remaining), startedAt);
    return { id: rows[0].user_id };
  }

  /** Drops cached lookups for revoked session hashes (Buffers). */
  async revokeCachedSessions(hashBuffers) {
    await this.store.forgetSessions(hashBuffers.map((b) => Buffer.from(b).toString('hex')));
  }

  /**
   * Call after deleting many of a user's sessions in Postgres (reset, change
   * password, account deletion): sets the revoked-at marker, then drops the
   * known cache entries. A session that is kept (change password) simply
   * gets re-read from Postgres once.
   */
  async revokeUserSessions(userId, hashBuffers = []) {
    await this.store.markSessionsRevoked(userId);
    await this.revokeCachedSessions(hashBuffers);
  }

  // ---------------------------------------------------------------------------
  // Contacts
  // ---------------------------------------------------------------------------

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

  /** Call after any change to the contact edges of these users. */
  async contactsChanged(...userIds) {
    await this.store.forgetContacts(...userIds);
  }

  // ---------------------------------------------------------------------------
  // Presence
  // ---------------------------------------------------------------------------

  async presence(ids) {
    return this.store.presence(ids);
  }
}
