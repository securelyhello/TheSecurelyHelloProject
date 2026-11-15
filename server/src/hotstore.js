// Redis: the short-lived, hot data, so Postgres (Neon, a network hop away)
// stays off the hot path.
//
// Keys (all prefixed with REDIS_PREFIX, default "sh:"):
//   rl:<bucket>:<key>        rate-limit counter (fixed window, PX = window)
//   sess:<sha256 hex>        session token → "<user id>:<ms the DB lookup began>" (short TTL)
//   revoked:<user>           ms at which all of the user's sessions were revoked
//                            (TTL = session cache TTL + margin)
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

// Sliding-window log: at most ARGV[3] hits in any ARGV[2] ms ending at ARGV[1].
// Rejected hits are not recorded. Used for hard caps (daily e-mail quota),
// where a fixed window could let up to twice the cap through around a
// window boundary.
const SLIDING_SCRIPT = `
local now = tonumber(ARGV[1])
local win = tonumber(ARGV[2])
redis.call('ZREMRANGEBYSCORE', KEYS[1], '-inf', now - win)
if redis.call('ZCARD', KEYS[1]) >= tonumber(ARGV[3]) then return 0 end
redis.call('ZADD', KEYS[1], now, ARGV[4])
redis.call('PEXPIRE', KEYS[1], win)
return 1`;

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
    redis.defineCommand('shSlidingHit', { numberOfKeys: 1, lua: SLIDING_SCRIPT });
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

  /**
   * Strict cap: true (and the hit is recorded) only if fewer than [capacity]
   * hits were recorded in the [windowMs] before [now].
   */
  async slidingHit(bucket, key, capacity, windowMs, now = Date.now()) {
    if (capacity <= 0) return false;
    const member = `${now}:${randomUUID()}`;
    const ok = await this.redis.shSlidingHit(this.k('rl', bucket, key), now, windowMs, capacity, member);
    return ok === 1;
  }

  /** Like rateHit() but records nothing: true if one more hit would fit. */
  async ratePeek(bucket, key, capacity) {
    const n = Number((await this.redis.get(this.k('rl', bucket, key))) ?? 0);
    return n + 1 <= capacity;
  }

  /** Like slidingHit() but records nothing: true if one more hit would fit. */
  async slidingPeek(bucket, key, capacity, windowMs, now = Date.now()) {
    if (capacity <= 0) return false;
    const n = await this.redis.zcount(this.k('rl', bucket, key), `(${now - windowMs}`, '+inf');
    return n < capacity;
  }

  // ---------------------------------------------------------------------------
  // Session cache
  // ---------------------------------------------------------------------------

  /**
   * Returns {userId, at} where [at] is when the DB lookup that produced the
   * entry began, or null. Entries in the old format (bare user id) count as
   * missing, so they are re-read from Postgres.
   */
  async getCachedSession(hashHex) {
    const raw = await this.redis.get(this.k('sess', hashHex));
    const i = raw ? raw.lastIndexOf(':') : -1;
    if (i <= 0) return null;
    const at = Number(raw.slice(i + 1));
    return Number.isFinite(at) ? { userId: raw.slice(0, i), at } : null;
  }

  /** [at]: when the DB lookup began (ms), compared against the revoked marker. */
  async cacheSession(hashHex, userId, maxSeconds, at = Date.now()) {
    const ttl = Math.max(1, Math.min(this.sessionCacheSeconds, Math.floor(maxSeconds)));
    await this.redis.set(this.k('sess', hashHex), `${userId}:${at}`, 'EX', ttl);
  }

  /**
   * Records that every session of [userId] up to [at] is revoked. Lives as
   * long as a cache entry can, which is all it needs to cover.
   */
  async markSessionsRevoked(userId, at = Date.now()) {
    await this.redis.set(this.k('revoked', userId), String(at), 'EX', this.sessionCacheSeconds + 60);
  }

  async sessionsRevokedAt(userId) {
    const raw = await this.redis.get(this.k('revoked', userId));
    return raw === null ? null : Number(raw);
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
