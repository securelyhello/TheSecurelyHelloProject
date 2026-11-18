// Rate limits backed by Redis fixed-window counters, so they survive restarts
// and are shared by every server instance.
//
// These sit *inside* the reverse proxy's own per-IP limits (Traefik: 50 req/s,
// 1500/min) and are deliberately tighter per account / per sender.

const MIN = 60_000;

export const DEFAULT_LIMITS = {
  // per client IP
  authIp: { capacity: 20, perMs: 10 * MIN },
  // per normalized e-mail (slows password guessing against one account)
  authAccount: { capacity: 10, perMs: 15 * MIN },
  // unauthenticated username availability checks, per IP
  publicIp: { capacity: 60, perMs: MIN },
  // general authenticated API calls, per user
  api: { capacity: 300, perMs: MIN },
  // prekey bundle claims, per user (each one spends a one-time prekey)
  prekeyClaim: { capacity: 60, perMs: MIN },
  // abuse reports, per user
  report: { capacity: 10, perMs: 60 * MIN },
  // attachment uploads, per user
  upload: { capacity: 60, perMs: 60 * MIN },
  // relay envelopes, per sender
  relay: { capacity: 120, perMs: MIN },
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
};

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
    return this.store.rateHit(name, key, def.capacity, def.perMs);
  }
}
