// Redis: the short-lived, hot data, so Postgres (Neon, a network hop away)
// stays off the hot path.
//
// Keys (all prefixed with REDIS_PREFIX, default "sh:"):
//   rl:<bucket>:<key>        rate-limit counter (fixed window, PX = window)
//   sess:<sha256 hex>        session token → user id cache (short TTL)
//   contacts:<user>          JSON array of contact ids (cache, short TTL)
//   online:<user>            "1" while a socket is connected (TTL, refreshed)
//   lastseen:<user>          ISO timestamp of the last disconnect (90 d TTL)
//   relay:m:<id>             one ciphertext envelope (JSON), PX = relay TTL
//   relay:q:<recipient>      ZSET of pending envelope ids, score = created ms
//   relay:s:<sender>         ZSET "<recipient>:<id>" (for account deletion)
//
// Every key carries a TTL. The relay queue must never be evicted silently, so
// the Redis instance runs with maxmemory-policy noeviction (see
// docker-compose.yml): under memory pressure writes fail loudly (HTTP 503)
// instead of dropping queued messages.
import { randomUUID } from 'node:crypto';

import Redis from 'ioredis';

export function createRedis(url, { name = 'securelyhello' } = {}) {
  if (!url) throw new Error('REDIS_URL is not set (see server/.env.example)');
  const redis = new Redis(url, {
    connectionName: name,
    maxRetriesPerRequest: 2,
    enableReadyCheck: true,
    // Reconnect with capped back-off; commands fail fast while disconnected
    // after maxRetriesPerRequest.
    retryStrategy: (times) => Math.min(times * 200, 5000),
  });
  return redis;
}

const ACK_SCRIPT = `
local n = 0
for i, id in ipairs(ARGV) do
  if redis.call('ZREM', KEYS[1], id) == 1 then
    redis.call('DEL', KEYS[2] .. id)
    n = n + 1
  end
end
return n`;

const RATE_SCRIPT = `
local c = redis.call('INCR', KEYS[1])
if c == 1 then redis.call('PEXPIRE', KEYS[1], ARGV[1]) end
return c`;

export class HotStore {
  /**
   * @param {import('ioredis').Redis} redis
   * @param {object} opts
   */
  constructor(
    redis,
    {
      prefix = 'sh:',
      relayTtlSeconds = 24 * 3600,
      relayQueueCap = 2000,
      sessionCacheSeconds = 300,
      contactCacheSeconds = 600,
      onlineTtlSeconds = 75,
    } = {},
  ) {
    this.redis = redis;
    this.p = prefix;
    this.relayTtlMs = relayTtlSeconds * 1000;
    this.relayQueueCap = relayQueueCap;
    this.sessionCacheSeconds = sessionCacheSeconds;
    this.contactCacheSeconds = contactCacheSeconds;
    this.onlineTtlSeconds = onlineTtlSeconds;
    redis.defineCommand('shRelayAck', { numberOfKeys: 2, lua: ACK_SCRIPT });
    redis.defineCommand('shRateHit', { numberOfKeys: 1, lua: RATE_SCRIPT });
  }

  k(...parts) {
    return this.p + parts.join(':');
  }

  async ping() {
    return (await this.redis.ping()) === 'PONG';
  }

  // ---------------------------------------------------------------------------
  // Rate limits: fixed window counters
  // ---------------------------------------------------------------------------

  /** Counts one hit; returns false once [capacity] is exceeded in the window. */
  async rateHit(bucket, key, capacity, windowMs) {
    const n = await this.redis.shRateHit(this.k('rl', bucket, key), windowMs);
    return n <= capacity;
  }

  // ---------------------------------------------------------------------------
  // Session cache
  // ---------------------------------------------------------------------------

  async getCachedSession(hashHex) {
    return this.redis.get(this.k('sess', hashHex));
  }

  async cacheSession(hashHex, userId, maxSeconds) {
    const ttl = Math.max(1, Math.min(this.sessionCacheSeconds, Math.floor(maxSeconds)));
    await this.redis.set(this.k('sess', hashHex), userId, 'EX', ttl);
  }

  async forgetSessions(hashHexes) {
    if (hashHexes.length) await this.redis.del(...hashHexes.map((h) => this.k('sess', h)));
  }

  // ---------------------------------------------------------------------------
  // Contact-list cache
  // ---------------------------------------------------------------------------

  async getCachedContacts(userId) {
    const raw = await this.redis.get(this.k('contacts', userId));
    return raw === null ? null : JSON.parse(raw);
  }

  async cacheContacts(userId, ids) {
    await this.redis.set(this.k('contacts', userId), JSON.stringify(ids), 'EX', this.contactCacheSeconds);
  }

  async forgetContacts(...userIds) {
    if (userIds.length) await this.redis.del(...userIds.map((id) => this.k('contacts', id)));
  }

  // ---------------------------------------------------------------------------
  // Presence
  // ---------------------------------------------------------------------------

  async markOnline(userIds) {
    if (!userIds.length) return;
    const m = this.redis.multi();
    for (const id of userIds) m.set(this.k('online', id), '1', 'EX', this.onlineTtlSeconds);
    await m.exec();
  }

  /** Clears the online flag and records last-seen; returns the timestamp. */
  async markOffline(userId) {
    const now = new Date().toISOString();
    await this.redis
      .multi()
      .del(this.k('online', userId))
      .set(this.k('lastseen', userId), now, 'EX', 90 * 24 * 3600)
      .exec();
    return now;
  }

  /** Map id → {online, last_seen} for [ids]. */
  async presence(ids) {
    const out = new Map();
    if (!ids.length) return out;
    const keys = ids.flatMap((id) => [this.k('online', id), this.k('lastseen', id)]);
    const vals = await this.redis.mget(...keys);
    ids.forEach((id, i) => out.set(id, { online: vals[2 * i] === '1', last_seen: vals[2 * i + 1] }));
    return out;
  }

  async forgetPresence(userId) {
    await this.redis.del(this.k('online', userId), this.k('lastseen', userId));
  }

  // ---------------------------------------------------------------------------
  // Relay queue (ciphertext envelopes only)
  // ---------------------------------------------------------------------------

  /** Stores one envelope; returns the stored message, or null if the queue is full. */
  async relayEnqueue(senderId, recipientId, envelope) {
    const q = this.k('relay', 'q', recipientId);
    const now = Date.now();
    await this.redis.zremrangebyscore(q, '-inf', now - this.relayTtlMs);
    if ((await this.redis.zcard(q)) >= this.relayQueueCap) return null;

    const id = randomUUID();
    const createdAt = new Date(now).toISOString();
    const message = { id, sender_id: senderId, recipient_id: recipientId, envelope, created_at: createdAt };
    const s = this.k('relay', 's', senderId);
    const res = await this.redis
      .multi()
      .set(this.k('relay', 'm', id), JSON.stringify(message), 'PX', this.relayTtlMs)
      .zadd(q, now, id)
      .pexpire(q, this.relayTtlMs)
      .zadd(s, now, `${recipientId}:${id}`)
      .pexpire(s, this.relayTtlMs)
      .exec();
    const failed = res.find(([err]) => err);
    if (failed) throw failed[0];
    return { ...message, expires_at: new Date(now + this.relayTtlMs).toISOString() };
  }

  /** Oldest-first pending envelopes for [recipientId]. Expired ones are pruned. */
  async relayFetch(recipientId, limit = 100) {
    const q = this.k('relay', 'q', recipientId);
    await this.redis.zremrangebyscore(q, '-inf', Date.now() - this.relayTtlMs);
    const ids = await this.redis.zrange(q, 0, limit - 1);
    if (!ids.length) return [];
    const raws = await this.redis.mget(...ids.map((id) => this.k('relay', 'm', id)));
    const rows = [];
    const gone = [];
    ids.forEach((id, i) => {
      if (raws[i] === null) {
        gone.push(id); // TTL fired between the prune and the read
        return;
      }
      const m = JSON.parse(raws[i]);
      rows.push({ id: m.id, sender_id: m.sender_id, envelope: m.envelope, created_at: m.created_at });
    });
    if (gone.length) await this.redis.zrem(q, ...gone);
    return rows;
  }

  /** Deletes envelopes addressed to [recipientId]; ids for anyone else are ignored. */
  async relayAck(recipientId, ids) {
    if (!ids.length) return 0;
    return this.redis.shRelayAck(this.k('relay', 'q', recipientId), this.k('relay', 'm', ''), ...ids);
  }

  /** Account deletion: drop everything queued to and from [userId]. */
  async relayPurgeUser(userId) {
    const q = this.k('relay', 'q', userId);
    const s = this.k('relay', 's', userId);
    const [received, sent] = await Promise.all([this.redis.zrange(q, 0, -1), this.redis.zrange(s, 0, -1)]);
    const m = this.redis.multi();
    for (const id of received) m.del(this.k('relay', 'm', id));
    for (const entry of sent) {
      const sep = entry.indexOf(':');
      const recipient = entry.slice(0, sep);
      const id = entry.slice(sep + 1);
      m.zrem(this.k('relay', 'q', recipient), id);
      m.del(this.k('relay', 'm', id));
    }
    m.del(q, s);
    await m.exec();
  }
}
