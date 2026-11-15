// Rate limits backed by Redis fixed-window counters, so they survive restarts
// and are shared by every server instance.
//
// These sit *inside* the reverse proxy's own per-IP limits (Traefik: 50 req/s,
// 1500/min) and are deliberately tighter per account / per sender.

const MIN = 60_000;
const HOUR = 60 * MIN;
const DAY = 24 * HOUR;

export const DEFAULT_LIMITS = {
  // per client IP
  authIp: { capacity: 20, perMs: 10 * MIN },
  // per normalized e-mail (slows password guessing against one account)
  authAccount: { capacity: 10, perMs: 15 * MIN },
  // unauthenticated username availability checks, per IP
  publicIp: { capacity: 60, perMs: MIN },
  // general authenticated API calls, per user
  api: { capacity: 300, perMs: MIN },
  // relay envelopes, per sender
  relay: { capacity: 120, perMs: MIN },
  // contact requests, per sender
  contactRequest: { capacity: 30, perMs: 60 * MIN },
  // WebSocket frames (signaling, acks, presence), per user
  wsFrames: { capacity: 600, perMs: MIN },
  // WebSocket connection attempts, per IP
  wsConnect: { capacity: 30, perMs: MIN },
  // password-reset requests, per client IP
  pwResetIp: { capacity: 5, perMs: HOUR },
  // password-reset requests, per lower-cased submitted e-mail (known or not)
  pwResetEmail: { capacity: 3, perMs: HOUR },
  // password-reset requests, per lower-cased submitted e-mail, per day
  pwResetEmailDaily: { capacity: 5, perMs: DAY },
  // password-reset requests, per client IP, per day
  pwResetIpDaily: { capacity: 20, perMs: DAY },
  // verification e-mail requests, per user
  emailVerifyUser: { capacity: 3, perMs: HOUR },
  // code guesses, per `reset:<email>` / `verify:<userId>`
  codeAttempt: { capacity: 10, perMs: 15 * MIN },
  // every e-mail we send, global key (provider free tiers have daily quotas).
  // createApp() sets the capacity from EMAIL_DAILY_CAP. Sliding window: never
  // more than the cap in any 24 h, which is what protects a shared provider
  // quota (a fixed window allows up to 2x around its boundary).
  emailDaily: { capacity: 90, perMs: DAY, sliding: true },
  // verification e-mails, global: a share of the daily cap, so resets always
  // have headroom (60 of the default 90).
  emailVerifyDaily: { capacity: 60, perMs: DAY, sliding: true },
  // TURN credential fetches, per user
  turnUser: { capacity: 30, perMs: HOUR },
};

/** Smallest EMAIL_DAILY_CAP that leaves room for both resets and verification. */
export const MIN_EMAIL_DAILY_CAP = 2;

/** Daily e-mail buckets for a given EMAIL_DAILY_CAP (verification gets 2/3). */
export function emailLimits(cap) {
  const dailyCap = Math.max(MIN_EMAIL_DAILY_CAP, Math.floor(Number(cap) || 0));
  return {
    emailDaily: { capacity: dailyCap, perMs: DAY, sliding: true },
    emailVerifyDaily: { capacity: Math.floor((dailyCap * 2) / 3), perMs: DAY, sliding: true },
  };
}

export class RateLimits {
  /** @param {import('./hotstore.js').HotStore} store */
  constructor(store, overrides = {}) {
    this.store = store;
    this.defs = { ...DEFAULT_LIMITS, ...overrides };
  }

  /** Resolves false when [key] has exhausted the [name] budget. */
  async take(name, key) {
    const def = this.defs[name];
    if (!def) throw new Error(`unknown rate limit ${name}`);
    if (def.sliding) return this.store.slidingHit(name, key, def.capacity, def.perMs);
    return this.store.rateHit(name, key, def.capacity, def.perMs);
  }

  /**
   * True when [key] still has budget in [name], without spending any. Racy by
   * nature: callers must still take() before acting.
   */
  async peek(name, key) {
    const def = this.defs[name];
    if (!def) throw new Error(`unknown rate limit ${name}`);
    if (def.sliding) return this.store.slidingPeek(name, key, def.capacity, def.perMs);
    return this.store.ratePeek(name, key, def.capacity);
  }
}
