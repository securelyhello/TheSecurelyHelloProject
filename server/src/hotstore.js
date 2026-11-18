// Redis: the short-lived, hot data, so Postgres (Neon, a network hop away)
// stays off the hot path.
//
// Keys (all prefixed with REDIS_PREFIX, default "sh:"):
//   rl:<bucket>:<key>        rate-limit counter (fixed window, PX = window), or
//                            for sliding limits a ZSET of hits scored by ms
//   sess:<sha256 hex>        session token → "<user id>|<device id>|<looked up at µs>"
//                            cache (short TTL)
//   sessrev:<user>           when the user's sessions were last revoked (Redis
//                            TIME, µs); cache entries looked up at or before it
//                            are ignored and not written
//   suspended:<user>         "1" while the account is suspended (rejects cached
//                            sessions; Postgres is the source of truth)
//   contacts:<user>          JSON array of contact ids (cache, short TTL)
//   devices:<user>           JSON array of the user's device ids (cache, short TTL)
//   online:<user>            ZSET of instances with a non-away socket of the user,
//                            score = when that claim expires (ms, refreshed)
//   sockets:<user>           ZSET of instances with any socket of the user (same scores)
//   devloc:<device>          the instance holding that device's socket (TTL, refreshed)
//   lock:<name>              short lock so periodic work runs on one instance
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
// KEYS[2] and KEYS[4] are key prefixes: the script touches keys it does not
// declare (message bodies, per-sender byte counters), so it needs a
// standalone Redis (or a single primary), not Redis Cluster. The other
// multi-key scripts here also assume every key lives on one node.
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

// Sliding-window logs over several keys at once (strict caps such as the
// daily e-mail quota, where a fixed window could let up to twice the cap
// through around a window boundary).
//
// KEYS: one sorted set per cap. ARGV: now ms ('' = Redis TIME), member, then
// window ms and capacity for each key. The clock is Redis TIME unless a test
// passes one, so every server instance (and peek vs take) agrees on it.
const SLIDING_NOW_MS = `
local now
if ARGV[1] == '' then
  local t = redis.call('TIME')
  now = tonumber(t[1]) * 1000 + math.floor(tonumber(t[2]) / 1000)
else
  now = tonumber(ARGV[1])
end`;

// Records one hit in every key only if each has fewer than its capacity in
// its window; otherwise records nothing. Returns 1 or 0.
const SLIDING_TAKE_SCRIPT = `
${SLIDING_NOW_MS}
for i = 1, #KEYS do
  redis.call('ZREMRANGEBYSCORE', KEYS[i], '-inf', now - tonumber(ARGV[1 + 2 * i]))
  if redis.call('ZCARD', KEYS[i]) >= tonumber(ARGV[2 + 2 * i]) then return 0 end
end
for i = 1, #KEYS do
  redis.call('ZADD', KEYS[i], now, ARGV[2])
  redis.call('PEXPIRE', KEYS[i], ARGV[1 + 2 * i])
end
return 1`;

// Same check as SLIDING_TAKE_SCRIPT, recording nothing: an entry counts if
// its score is after now - window, including entries "in the future" written
// by a skewed caller, exactly as ZREMRANGEBYSCORE + ZCARD count them.
const SLIDING_PEEK_SCRIPT = `
${SLIDING_NOW_MS}
for i = 1, #KEYS do
  local floor = string.format('(%.0f', now - tonumber(ARGV[1 + 2 * i]))
  if redis.call('ZCOUNT', KEYS[i], floor, '+inf') >= tonumber(ARGV[2 + 2 * i]) then return 0 end
end
return 1`;

// Redis TIME in microseconds: one clock for every server instance.
const NOW_US = `local t = redis.call('TIME')
local now = tonumber(t[1]) * 1000000 + tonumber(t[2])`;

// A cached session, with the user's revocation marker and suspension flag.
// KEYS: session. ARGV: key prefix. Returns false or {raw, revoked at, suspended}.
// Reads keys it does not declare in KEYS (they depend on the session's
// value), so it needs a standalone Redis (or a single-primary setup), not
// Redis Cluster, where they could live on another shard.
const SESSION_GET_SCRIPT = `
local raw = redis.call('GET', KEYS[1])
if not raw then return false end
local uid = string.match(raw, '^([^|]*)')
local rev = redis.call('GET', ARGV[1] .. 'sessrev:' .. uid) or '0'
return {raw, rev, redis.call('EXISTS', ARGV[1] .. 'suspended:' .. uid)}`;

// Caches a session looked up at ARGV[2] (µs), unless the user's sessions were
// revoked since then or the user is suspended.
// KEYS: session, revocation marker, suspension flag. ARGV: value, looked up at, ttl s.
const SESSION_PUT_SCRIPT = `
if tonumber(redis.call('GET', KEYS[2]) or '0') >= tonumber(ARGV[2]) then return 0 end
if redis.call('EXISTS', KEYS[3]) == 1 then return 0 end
redis.call('SET', KEYS[1], ARGV[1], 'EX', ARGV[3])
return 1`;

// Stamps the user's revocation marker with the current Redis time.
// KEYS: revocation marker. ARGV: ttl s.
const SESSION_REVOKE_SCRIPT = `
${NOW_US}
redis.call('SET', KEYS[1], string.format('%d', now), 'EX', ARGV[1])
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
    // Variable key count: the first argument is the number of keys.
    redis.defineCommand('shSlidingTake', { lua: SLIDING_TAKE_SCRIPT });
    redis.defineCommand('shSlidingPeek', { lua: SLIDING_PEEK_SCRIPT });
    redis.defineCommand('shSessionGet', { numberOfKeys: 1, lua: SESSION_GET_SCRIPT });
    redis.defineCommand('shSessionPut', { numberOfKeys: 3, lua: SESSION_PUT_SCRIPT });
    redis.defineCommand('shSessionRevoke', { numberOfKeys: 1, lua: SESSION_REVOKE_SCRIPT });
  }

  k(...parts) {
    return this.p + parts.join(':');
  }

  /**
   * Claims "the running instance" for [ttlMs]. Returns the id of another
   * instance holding it, or null. Realtime state lives in one process, so
   * two instances would split sockets and presence.
   */
  /** True for the one caller that gets [name] for [ttlMs]. */
  async tryLock(name, ttlMs) {
    return (await this.redis.set(this.k('lock', name), '1', 'PX', ttlMs, 'NX')) === 'OK';
  }

  async ping() {
    return (await this.redis.ping()) === 'PONG';
  }

  // Rate limits: fixed window counters

  /** Hits counted so far in the current window. */
  async rateCount(bucket, key) {
    return Number(await this.redis.get(this.k('rl', bucket, key))) || 0;
  }

  /** Counts one hit; returns false once [capacity] is exceeded in the window. */
  async rateHit(bucket, key, capacity, windowMs) {
    const n = await this.redis.shRateHit(this.k('rl', bucket, key), windowMs);
    return n <= capacity;
  }

  /** Like rateHit() but records nothing: true if one more hit would fit. */
  async ratePeek(bucket, key, capacity) {
    return (await this.rateCount(bucket, key)) + 1 <= capacity;
  }

  // Rate limits: sliding windows (strict caps)

  /**
   * True (and the hit is recorded) only if fewer than [capacity] hits were
   * recorded in the [windowMs] up to now. [now] (ms) overrides the Redis
   * clock, for tests.
   */
  async slidingHit(bucket, key, capacity, windowMs, now) {
    return this.slidingTakeAll([{ bucket, key, capacity, windowMs }], now);
  }

  /** Like slidingHit() but records nothing: true if one more hit would fit. */
  async slidingPeek(bucket, key, capacity, windowMs, now) {
    return this.slidingPeekAll([{ bucket, key, capacity, windowMs }], now);
  }

  /**
   * Atomically records one hit in every cap of [caps] ({bucket, key,
   * capacity, windowMs}) if all of them have room, else records nothing.
   * The clock is Redis TIME unless [now] (ms) is given.
   */
  async slidingTakeAll(caps, now) {
    if (caps.some((c) => c.capacity <= 0)) return false;
    const member = `${now ?? ''}:${randomUUID()}`;
    return (await this.redis.shSlidingTake(...this.#slidingArgs(caps, now, member))) === 1;
  }

  /** Like slidingTakeAll() but records nothing: true if every cap has room. */
  async slidingPeekAll(caps, now) {
    if (caps.some((c) => c.capacity <= 0)) return false;
    return (await this.redis.shSlidingPeek(...this.#slidingArgs(caps, now, ''))) === 1;
  }

  #slidingArgs(caps, now, member) {
    const keys = caps.map((c) => this.k('rl', c.bucket, c.key));
    const limits = caps.flatMap((c) => [c.windowMs, c.capacity]);
    return [keys.length, ...keys, now ?? '', member, ...limits];
  }

  // Session cache

  /** How long revocation and suspension markers outlive any cache entry. */
  get #markerSeconds() {
    return this.sessionCacheSeconds + 3600;
  }

  /** Redis TIME in microseconds; pass it to cacheSession() as [lookedUpAt]. */
  async clockMicros() {
    const [sec, usec] = await this.redis.time();
    return Number(sec) * 1_000_000 + Number(usec);
  }

  /**
   * {id, deviceId} or null. Entries looked up before the user's sessions were
   * last revoked, and entries of suspended users, count as misses.
   */
  async getCachedSession(hashHex) {
    const res = await this.redis.shSessionGet(this.k('sess', hashHex), this.p);
    if (!res) return null;
    const [raw, revokedAt, suspended] = res;
    const [id, deviceId, lookedUpAt] = raw.split('|');
    if (Number(suspended) === 1) return null;
    if (!(Number(lookedUpAt) > Number(revokedAt))) return null;
    return { id, deviceId: deviceId || null };
  }

  /**
   * Caches a session row read from Postgres at [lookedUpAt] (clockMicros()
   * taken before the query). Skipped if the user's sessions were revoked
   * since, so a lookup racing a revocation can't re-cache a dead token.
   */
  async cacheSession(hashHex, userId, deviceId, maxSeconds, lookedUpAt) {
    const ttl = Math.max(1, Math.min(this.sessionCacheSeconds, Math.floor(maxSeconds)));
    await this.redis.shSessionPut(
      this.k('sess', hashHex),
      this.k('sessrev', userId),
      this.k('suspended', userId),
      `${userId}|${deviceId ?? ''}|${lookedUpAt}`,
      lookedUpAt,
      ttl,
    );
  }

  async forgetSessions(hashHexes) {
    if (hashHexes.length) await this.redis.del(...hashHexes.map((h) => this.k('sess', h)));
  }

  /** Every session of [userId] cached until now is stale. */
  async markSessionsRevoked(userId) {
    await this.redis.shSessionRevoke(this.k('sessrev', userId), this.#markerSeconds);
  }

  async markSuspended(userId) {
    await this.redis.set(this.k('suspended', userId), '1', 'EX', this.#markerSeconds);
  }

  async clearSuspended(userId) {
    await this.redis.del(this.k('suspended', userId));
  }

  // Contact-list cache

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

  // Device-list cache

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

  // Push throttle

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

  // Presence

  // Presence and routing. Each server instance claims the users (and
  // devices) it holds sockets for; claims expire unless refreshed, so a
  // crashed instance stops counting on its own.

  /** Adds [instance]'s claim to [kind] (online | sockets) for [userIds];
   * returns the users nobody had claimed before. */
  async #claim(kind, userIds, instance) {
    if (!userIds.length) return [];
    const now = Date.now();
    const until = now + this.onlineTtlSeconds * 1000;
    const m = this.redis.multi();
    for (const id of userIds) {
      const key = this.k(kind, id);
      m.zremrangebyscore(key, '-inf', now).zcard(key).zadd(key, until, instance).expire(key, this.onlineTtlSeconds);
    }
    const res = await m.exec();
    return userIds.filter((_, i) => res[i * 4 + 1][1] === 0);
  }

  /** Drops [instance]'s claim; returns how many instances still claim [userId]. */
  async #release(kind, userId, instance) {
    const key = this.k(kind, userId);
    const res = await this.redis.multi().zrem(key, instance).zremrangebyscore(key, '-inf', Date.now()).zcard(key).exec();
    return res[2][1];
  }

  /** [instance] has a non-away socket for each of [userIds]; returns those who just came online. */
  markOnline(userIds, instance) {
    return this.#claim('online', userIds, instance);
  }

  /** [instance] has no non-away socket of [userId] left. If no instance
   * has one, records last-seen and returns it; otherwise null. */
  async markOffline(userId, instance) {
    if ((await this.#release('online', userId, instance)) > 0) return null;
    const now = new Date().toISOString();
    await this.redis.set(this.k('lastseen', userId), now, 'EX', 90 * 24 * 3600);
    return now;
  }

  /** Map id → {online, last_seen} for [ids]. */
  async presence(ids) {
    const out = new Map();
    if (!ids.length) return out;
    const now = Date.now();
    const m = this.redis.multi();
    for (const id of ids) m.zcount(this.k('online', id), now, '+inf').get(this.k('lastseen', id));
    const res = await m.exec();
    ids.forEach((id, i) => out.set(id, { online: res[2 * i][1] > 0, last_seen: res[2 * i + 1][1] }));
    return out;
  }

  async forgetPresence(userId) {
    await this.redis.del(this.k('online', userId), this.k('lastseen', userId));
  }

  /** [instance] holds sockets (away or not) of [userIds]. */
  async noteSockets(userIds, instance) {
    await this.#claim('sockets', userIds, instance);
  }

  async dropSockets(userId, instance) {
    await this.#release('sockets', userId, instance);
  }

  /** Instances that hold sockets of [userId]. */
  async socketInstances(userId) {
    return this.redis.zrangebyscore(this.k('sockets', userId), Date.now(), '+inf');
  }

  /** [instance] holds the sockets of [deviceIds]. */
  async noteDevices(deviceIds, instance) {
    if (!deviceIds.length) return;
    const m = this.redis.multi();
    for (const d of deviceIds) m.set(this.k('devloc', d), instance, 'EX', this.onlineTtlSeconds);
    await m.exec();
  }

  /** Forgets where [deviceId] is, unless another instance has claimed it since. */
  async dropDevice(deviceId, instance) {
    await this.redis.eval(
      "if redis.call('GET', KEYS[1]) == ARGV[1] then return redis.call('DEL', KEYS[1]) end return 0",
      1,
      this.k('devloc', deviceId),
      instance,
    );
  }

  /** The instance holding [deviceId]'s socket, if any. */
  async deviceInstance(deviceId) {
    return this.redis.get(this.k('devloc', deviceId));
  }

  // Relay queue (ciphertext envelopes only)

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
