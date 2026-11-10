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

  /** Resolves a bearer token to {id} or null. Cached in Redis for minutes. */
  async authenticate(token) {
    const hex = hashToken(token).toString('hex');
    const cached = await this.store.getCachedSession(hex);
    if (cached) return { id: cached };
    const { rows } = await this.pool.query(
      `UPDATE sessions SET last_used_at = now()
        WHERE token_hash = $1 AND expires_at > now()
        RETURNING user_id, extract(epoch FROM expires_at - now()) AS remaining`,
      [Buffer.from(hex, 'hex')],
    );
    if (!rows[0]) return null;
    await this.store.cacheSession(hex, rows[0].user_id, Number(rows[0].remaining));
    return { id: rows[0].user_id };
  }

  /** Drops cached lookups for revoked session hashes (Buffers). */
  async revokeCachedSessions(hashBuffers) {
    await this.store.forgetSessions(hashBuffers.map((b) => Buffer.from(b).toString('hex')));
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
