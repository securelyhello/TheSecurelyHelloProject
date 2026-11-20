// Rate limits backed by Redis (fixed-window counters, or sliding windows for
// hard caps), so they survive restarts and are shared by every server
// instance.
//
// These sit *inside* the reverse proxy's own per-IP limits (Traefik: 50 req/s,
// 1500/min) and are deliberately tighter per account / per sender.

const MIN = 60_000;
const DAY = 24 * 60 * MIN;

export const DEFAULT_LIMITS = {
  // per client IP
  authIp: { capacity: 20, perMs: 10 * MIN },
  // per normalized e-mail and client IP (slows password guessing)
  authAccount: { capacity: 10, perMs: 15 * MIN },
  // wrong passwords per normalized e-mail from anywhere (spread-out guessing);
  // only failures count, so the owner's right password is never the reason
  authFailures: { capacity: 100, perMs: 60 * MIN },
  // unauthenticated username availability checks, per IP
  publicIp: { capacity: 60, perMs: MIN },
  // general authenticated API calls, per user
  api: { capacity: 300, perMs: MIN },
  // prekey bundle claims, per user (each one spends a one-time prekey)
  prekeyClaim: { capacity: 60, perMs: MIN },
  // claims that spend one-time prekeys, per requester and target user (not
  // for your own devices); past these the bundle carries only the signed
  // prekey, so a contact can't drain someone's one-time prekeys
  prekeyPair: { capacity: 10, perMs: MIN },
  prekeyPairDaily: { capacity: 100, perMs: DAY },
  // abuse reports, per user
  report: { capacity: 10, perMs: 60 * MIN },
  // attachment uploads, per user
  upload: { capacity: 60, perMs: 60 * MIN },
  // relay calls, per sender; a group message is one call per member
  relay: { capacity: 600, perMs: MIN },
  // creating groups and changing their members, per user
  groupChange: { capacity: 60, perMs: 60 * MIN },
  // contact requests, per sender
  contactRequest: { capacity: 30, perMs: 60 * MIN },
  // contact requests from accounts less than a day old, per sender
  contactRequestNew: { capacity: 10, perMs: 24 * 60 * MIN },
  // invite links created, per user
  invite: { capacity: 20, perMs: 24 * 60 * MIN },
  // invite lookups and accepts, per user
  inviteLookup: { capacity: 30, perMs: 60 * MIN },
  // address-book matching, per user (each call up to 500 hashes)
  discovery: { capacity: 5, perMs: 60 * MIN },
  // new accounts, per client IP
  signupIp: { capacity: 10, perMs: 24 * 60 * MIN },
  // WebSocket frames (signaling, acks, presence), per user
  wsFrames: { capacity: 600, perMs: MIN },
  // verification / reset e-mails, per account or address
  emailSend: { capacity: 5, perMs: 60 * MIN },
  // two-step codes, per account
  otp: { capacity: 10, perMs: 15 * MIN },
  // WebSocket connection attempts, per IP
  wsConnect: { capacity: 30, perMs: MIN },
  // stories posted, per user, in any 24 h (sized from STORIES_PER_DAY by
  // createApp); counts posts, so deleting a story doesn't give one back
  storyPost: { capacity: 30, perMs: DAY, sliding: true },
  // Every e-mail we send (verification, reset, device codes), global key.
  // createApp() sizes both caps from EMAIL_DAILY_CAP (see emailLimits()).
  // Sliding windows: never more than the cap in any 24 h, which is what
  // protects a provider quota shared with other products (a fixed window
  // allows up to twice the cap around its boundary).
  emailDaily: { capacity: 40, perMs: DAY, sliding: true },
  // Verification e-mails, global: two thirds of the cap, so a sign-up wave
  // can't use the headroom password resets and device recovery need.
  emailVerifyDaily: { capacity: 26, perMs: DAY, sliding: true },
};

/** Smallest EMAIL_DAILY_CAP that leaves room for both resets and verification. */
export const MIN_EMAIL_DAILY_CAP = 2;

/** The two global e-mail caps for an EMAIL_DAILY_CAP (verification gets 2/3). */
export function emailLimits(cap) {
  const daily = Math.max(MIN_EMAIL_DAILY_CAP, Math.floor(Number(cap)) || 0);
  return {
    emailDaily: { capacity: daily, perMs: DAY, sliding: true },
    emailVerifyDaily: { capacity: Math.floor((daily * 2) / 3), perMs: DAY, sliding: true },
  };
}

export class RateLimits {
  /** @param {import('./hotstore.js').HotStore} store */
  constructor(store, overrides = {}) {
    this.store = store;
    this.defs = { ...DEFAULT_LIMITS, ...overrides };
  }

  /** Whether [key] has used up the [name] budget, without using any. */
  async exhausted(name, key) {
    return !(await this.peek(name, key));
  }

  /** Resolves false when [key] has exhausted the [name] budget. */
  async take(name, key) {
    const def = this.#def(name);
    if (def.sliding) return this.store.slidingHit(name, key, def.capacity, def.perMs);
    return this.store.rateHit(name, key, def.capacity, def.perMs);
  }

  /**
   * True when [key] still has budget in [name], without spending any. Racy by
   * nature: callers must still take() before acting.
   */
  async peek(name, key) {
    const def = this.#def(name);
    if (def.sliding) return this.store.slidingPeek(name, key, def.capacity, def.perMs);
    return this.store.ratePeek(name, key, def.capacity);
  }

  /**
   * Atomically takes one hit from every sliding limit in [names] for [key],
   * or none of them: false if any is used up.
   */
  async takeAll(names, key) {
    return this.store.slidingTakeAll(this.#slidingCaps(names, key));
  }

  /** Like takeAll() but spends nothing (same clock and counting as takeAll). */
  async peekAll(names, key) {
    return this.store.slidingPeekAll(this.#slidingCaps(names, key));
  }

  #slidingCaps(names, key) {
    return names.map((name) => {
      const def = this.#def(name);
      if (!def.sliding) throw new Error(`rate limit ${name} is not a sliding window`);
      return { bucket: name, key, capacity: def.capacity, windowMs: def.perMs };
    });
  }

  #def(name) {
    const def = this.defs[name];
    if (!def) throw new Error(`unknown rate limit ${name}`);
    return def;
  }
}
