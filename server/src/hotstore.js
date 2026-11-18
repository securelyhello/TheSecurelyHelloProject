// Redis: the short-lived, hot data, so Postgres (Neon, a network hop away)
// stays off the hot path.
//
// Keys (all prefixed with REDIS_PREFIX, default "sh:"):
//   rl:<bucket>:<key>        rate-limit counter (fixed window, PX = window)
//   sess:<sha256 hex>        session token → "<user id>|<device id>" cache (short TTL)
//   contacts:<user>          JSON array of contact ids (cache, short TTL)
//   devices:<user>           JSON array of the user's device ids (cache, short TTL)
//   online:<user>            "1" while a socket is connected (TTL, refreshed)
//   lastseen:<user>          ISO timestamp of the last disconnect (90 d TTL)
//   relay:m:<id>             one ciphertext envelope (JSON), PX = relay TTL
//   relay:q:<device>         ZSET of envelope ids pending for one device, score = created ms
//   relay:s:<sender user>    ZSET "<recipient device>:<id>" (for account deletion)
//   push:<device>            "1" while a push wake-up is throttled
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

// Acked messages give their bytes back to the recipient's and the
// sender's budgets.
const ACK_SCRIPT = `
local n = 0
for i, id in ipairs(ARGV) do
  if redis.call('ZREM', KEYS[1], id) == 1 then
    local raw = redis.call('GET', KEYS[2] .. id)
    if raw then
      local len = string.len(raw)
      if redis.call('DECRBY', KEYS[3], len) < 0 then redis.call('SET', KEYS[3], 0, 'KEEPTTL') end
      local ok, msg = pcall(cjson.decode, raw)
      if ok and msg.sender_id then
        local s = KEYS[4] .. msg.sender_id
        if redis.call('DECRBY', s, len) < 0 then redis.call('SET', s, 0, 'KEEPTTL') end
      end
    end
    redis.call('DEL', KEYS[2] .. id)
    n = n + 1
  end
end
return n`;

// Atomic enqueue with a count cap and byte budgets per recipient device and
// per sender, so one account can't fill Redis (audit run 1, U2-2).
// KEYS: queue, message, sender index, device bytes, sender bytes.
// ARGV: now, ttl ms, count cap, id, json, device byte cap, sender byte cap, sender index member.
// Returns 1, or 0 (queue full by count), -1 (device bytes), -2 (sender bytes).
const ENQUEUE_SCRIPT = `
local now = tonumber(ARGV[1])
local ttl = tonumber(ARGV[2])
redis.call('ZREMRANGEBYSCORE', KEYS[1], '-inf', now - ttl)
local count = redis.call('ZCARD', KEYS[1])
if count >= tonumber(ARGV[3]) then return 0 end
if count == 0 then redis.call('DEL', KEYS[4]) end
local size = string.len(ARGV[5])
if (tonumber(redis.call('GET', KEYS[4])) or 0) + size > tonumber(ARGV[6]) then return -1 end
if (tonumber(redis.call('GET', KEYS[5])) or 0) + size > tonumber(ARGV[7]) then return -2 end
redis.call('SET', KEYS[2], ARGV[5], 'PX', ttl)
redis.call('ZADD', KEYS[1], now, ARGV[4])
redis.call('PEXPIRE', KEYS[1], ttl)
redis.call('ZADD', KEYS[3], now, ARGV[8])
redis.call('PEXPIRE', KEYS[3], ttl)
redis.call('INCRBY', KEYS[4], size)
redis.call('PEXPIRE', KEYS[4], ttl)
redis.call('INCRBY', KEYS[5], size)
redis.call('PEXPIRE', KEYS[5], ttl)
return 1`;

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
      relayDeviceBytes = 16 * 1024 * 1024,
      relaySenderBytes = 32 * 1024 * 1024,
      sessionCacheSeconds = 300,
      contactCacheSeconds = 600,
      onlineTtlSeconds = 75,
    } = {},
  ) {
    this.redis = redis;
    this.p = prefix;
    this.relayTtlMs = relayTtlSeconds * 1000;
    this.relayQueueCap = relayQueueCap;
    this.relayDeviceBytes = relayDeviceBytes;
    this.relaySenderBytes = relaySenderBytes;
    this.sessionCacheSeconds = sessionCacheSeconds;
    this.contactCacheSeconds = contactCacheSeconds;
    this.onlineTtlSeconds = onlineTtlSeconds;
    redis.defineCommand('shRelayAck', { numberOfKeys: 4, lua: ACK_SCRIPT });
    redis.defineCommand('shRelayEnqueue', { numberOfKeys: 5, lua: ENQUEUE_SCRIPT });
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

  /** {id, deviceId} or null. */
  async getCachedSession(hashHex) {
    const raw = await this.redis.get(this.k('sess', hashHex));
    if (raw === null) return null;
    const [id, deviceId] = raw.split('|');
    return { id, deviceId: deviceId || null };
  }

  async cacheSession(hashHex, userId, deviceId, maxSeconds) {
    const ttl = Math.max(1, Math.min(this.sessionCacheSeconds, Math.floor(maxSeconds)));
    await this.redis.set(this.k('sess', hashHex), `${userId}|${deviceId ?? ''}`, 'EX', ttl);
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
  // Device-list cache
  // ---------------------------------------------------------------------------

  async getCachedDevices(userId) {
    const raw = await this.redis.get(this.k('devices', userId));
    return raw === null ? null : JSON.parse(raw);
  }

  async cacheDevices(userId, ids) {
    await this.redis.set(this.k('devices', userId), JSON.stringify(ids), 'EX', this.contactCacheSeconds);
  }

  async forgetDevices(...userIds) {
    if (userIds.length) await this.redis.del(...userIds.map((id) => this.k('devices', id)));
  }

  // ---------------------------------------------------------------------------
  // Push throttle
  // ---------------------------------------------------------------------------

  /** True if a wake-up may be sent to [deviceId] now (at most one per window). */
  /** Stores a proof-of-work challenge for [ttlSeconds]. */
  async putChallenge(challenge, purpose, ttlSeconds) {
    await this.redis.set(this.k('pow', challenge), purpose, 'EX', ttlSeconds);
  }

  /** Removes the challenge and returns its purpose (null if unknown or used). */
  async takeChallenge(challenge) {
    return this.redis.getdel(this.k('pow', challenge));
  }

  async takePushSlot(deviceId, windowSeconds) {
    return (await this.redis.set(this.k('push', deviceId), '1', 'EX', windowSeconds, 'NX')) === 'OK';
  }

  async clearPushSlot(deviceId) {
    await this.redis.del(this.k('push', deviceId));
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

  /**
   * Stores one envelope for one device; returns the stored message, or null
   * if that device's queue is full.
   */
  async relayEnqueue({ senderId, senderDevice, recipientId, recipientDevice, envelope }) {
    const q = this.k('relay', 'q', recipientDevice);
    const now = Date.now();
    const id = randomUUID();
    const createdAt = new Date(now).toISOString();
    const message = {
      id,
      sender_id: senderId,
      sender_device: senderDevice,
      recipient_id: recipientId,
      recipient_device: recipientDevice,
      envelope,
      created_at: createdAt,
    };
    const r = await this.redis.shRelayEnqueue(
      q,
      this.k('relay', 'm', id),
      this.k('relay', 's', senderId),
      this.k('relay', 'qb', recipientDevice),
      this.k('relay', 'sb', senderId),
      now,
      this.relayTtlMs,
      this.relayQueueCap,
      id,
      JSON.stringify(message),
      this.relayDeviceBytes,
      this.relaySenderBytes,
      `${recipientDevice}:${id}`,
    );
    if (r === 0 || r === -1) return { full: 'recipient' };
    if (r === -2) return { full: 'sender' };
    return { ...message, expires_at: new Date(now + this.relayTtlMs).toISOString() };
  }

  /** Oldest-first pending envelopes for [deviceId]. Expired ones are pruned. */
  async relayFetch(deviceId, limit = 100) {
    const q = this.k('relay', 'q', deviceId);
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
      rows.push({
        id: m.id,
        sender_id: m.sender_id,
        sender_device: m.sender_device,
        envelope: m.envelope,
        created_at: m.created_at,
      });
    });
    if (gone.length) await this.redis.zrem(q, ...gone);
    return rows;
  }

  async relayPending(deviceId) {
    return this.redis.zcard(this.k('relay', 'q', deviceId));
  }

  /** Deletes envelopes addressed to [deviceId]; ids for anyone else are ignored. */
  async relayAck(deviceId, ids) {
    if (!ids.length) return 0;
    return this.redis.shRelayAck(
      this.k('relay', 'q', deviceId),
      this.k('relay', 'm', ''),
      this.k('relay', 'qb', deviceId),
      this.k('relay', 'sb', ''),
      ...ids,
    );
  }

  /** Device removed: drop everything still queued for it. */
  async relayPurgeDevice(deviceId) {
    const q = this.k('relay', 'q', deviceId);
    const received = await this.redis.zrange(q, 0, -1);
    const m = this.redis.multi();
    for (const id of received) m.del(this.k('relay', 'm', id));
    m.del(q, this.k('push', deviceId), this.k('relay', 'qb', deviceId));
    await m.exec();
  }

  /** Account deletion: drop everything queued to [deviceIds] and sent by [userId]. */
  async relayPurgeUser(userId, deviceIds = []) {
    for (const d of deviceIds) await this.relayPurgeDevice(d);
    const s = this.k('relay', 's', userId);
    const sent = await this.redis.zrange(s, 0, -1);
    const m = this.redis.multi();
    for (const entry of sent) {
      const sep = entry.indexOf(':');
      const recipient = entry.slice(0, sep);
      const id = entry.slice(sep + 1);
      m.zrem(this.k('relay', 'q', recipient), id);
      m.del(this.k('relay', 'm', id));
    }
    m.del(s);
    await m.exec();
  }
}
