// Spam and bot defenses. Messages are end-to-end encrypted, so nothing here
// looks at content: it raises the cost of making accounts and restricts
// accounts that other people push away.
//
// - Proof of work: signing up and asking for a reset e-mail need a solved
//   challenge (SHA-256 with POW_BITS leading zero bits; about a second on a
//   phone, expensive in bulk). Challenges are single use.
// - Disposable e-mail domains are refused at signup.
// - New accounts (first day) get a tighter contact-request quota.
// - Restriction: an account reported by several different people, blocked
//   by several, or with most of its recent requests rejected can't send new
//   contact requests until it expires or an operator lifts it. Existing
//   contacts are unaffected.
import { createHash, randomBytes } from 'node:crypto';

import { DISPOSABLE_DOMAINS } from './disposable_domains.js';
import { HttpError, bad } from './validate.js';

export const SPAM_THRESHOLDS = {
  reportersPerWeek: 3,
  blockersPerWeek: 5,
  rejectedPerDay: 10,
  rejectedShare: 0.8,
  newAccountHours: 24,
};

const CHALLENGE_TTL_SECONDS = 600;

/** Leading zero bits of a hash. */
export function leadingZeroBits(buf) {
  let n = 0;
  for (const byte of buf) {
    if (byte === 0) {
      n += 8;
      continue;
    }
    return n + Math.clz32(byte) - 24;
  }
  return n;
}

export const powHash = (purpose, challenge, nonce) =>
  createHash('sha256').update(`securelyhello-pow|${purpose}|${challenge}|${nonce}`).digest();

/** The smallest nonce solving [challenge] (tests and tools). */
export function solvePow(purpose, challenge, bits) {
  for (let nonce = 0; ; nonce++) {
    if (leadingZeroBits(powHash(purpose, challenge, nonce)) >= bits) return String(nonce);
  }
}

export function isDisposableEmail(email) {
  const domain = email.split('@').pop().toLowerCase();
  const parts = domain.split('.');
  // Subdomains of a listed domain count too (x.mailinator.com).
  for (let i = 0; i < parts.length - 1; i++) {
    if (DISPOSABLE_DOMAINS.has(parts.slice(i).join('.'))) return true;
  }
  return false;
}

export function createAntiSpam({ pool, store, config, log }) {
  const bits = config.powBits;

  async function issueChallenge(purpose) {
    const challenge = randomBytes(16).toString('base64url');
    await store.putChallenge(challenge, purpose, CHALLENGE_TTL_SECONDS);
    return { challenge, bits, purpose, expires_in: CHALLENGE_TTL_SECONDS };
  }

  /** Throws unless [pow] is a fresh, solved challenge for [purpose]. */
  async function requirePow(purpose, pow) {
    if (bits === 0) return;
    if (!pow || typeof pow !== 'object' || typeof pow.challenge !== 'string' || typeof pow.nonce !== 'string') {
      throw new HttpError(428, 'pow_required', 'Solve the challenge from /api/auth/challenge first');
    }
    if (pow.challenge.length > 64 || pow.nonce.length > 32) throw bad('Malformed challenge');
    const issuedFor = await store.takeChallenge(pow.challenge);
    if (issuedFor !== purpose || leadingZeroBits(powHash(purpose, pow.challenge, pow.nonce)) < bits) {
      throw new HttpError(428, 'pow_invalid', 'The challenge expired or the answer is wrong. Try again.');
    }
  }

  function checkSignupEmail(email) {
    if (config.blockDisposableEmail && isDisposableEmail(email)) {
      throw new HttpError(422, 'disposable_email', 'Please use a permanent e-mail address');
    }
  }

  /** Throws if [userId] may not send contact requests right now. */
  async function checkCanRequest(userId) {
    const { rows } = await pool.query(
      `SELECT restricted_until, created_at > now() - make_interval(hours => $2) AS is_new
         FROM users WHERE id = $1`,
      [userId, SPAM_THRESHOLDS.newAccountHours],
    );
    const row = rows[0];
    if (row?.restricted_until && row.restricted_until > new Date()) {
      throw new HttpError(
        403,
        'restricted',
        "Your account can't send contact requests for now because several people rejected, blocked or " +
          'reported it. Your existing chats still work.',
      );
    }
    return { isNew: row?.is_new === true };
  }

  /**
   * Re-evaluates [userId] after someone reported, blocked or rejected them,
   * and restricts the account when the signals add up. Returns the reason
   * or null.
   */
  async function evaluate(userId) {
    const { rows } = await pool.query(
      `SELECT
         (SELECT count(DISTINCT reporter_id)::int FROM reports
           WHERE reported_id = $1 AND related AND created_at > now() - interval '7 days') AS reporters,
         (SELECT count(*)::int FROM blocks
           WHERE blocked_id = $1 AND related AND created_at > now() - interval '7 days') AS blockers,
         (SELECT count(*) FILTER (WHERE status = 'rejected')::int FROM contact_requests
           WHERE sender_id = $1 AND updated_at > now() - interval '1 day') AS rejected,
         (SELECT count(*) FILTER (WHERE status IN ('rejected', 'accepted'))::int FROM contact_requests
           WHERE sender_id = $1 AND updated_at > now() - interval '1 day') AS decided`,
      [userId],
    );
    const s = rows[0];
    const t = SPAM_THRESHOLDS;
    let reason = null;
    let hours = 0;
    if (s.reporters >= t.reportersPerWeek) [reason, hours] = ['reports', 7 * 24];
    else if (s.blockers >= t.blockersPerWeek) [reason, hours] = ['blocks', 7 * 24];
    else if (s.rejected >= t.rejectedPerDay && s.rejected / s.decided >= t.rejectedShare) [reason, hours] = ['rejections', 24];
    if (!reason) return null;
    const res = await pool.query(
      `UPDATE users SET restricted_until = GREATEST(COALESCE(restricted_until, now()), now() + make_interval(hours => $2)),
              restricted_reason = $3
        WHERE id = $1 AND (restricted_until IS NULL OR restricted_until < now() + make_interval(hours => $2))`,
      [userId, hours, reason],
    );
    if (res.rowCount) log.info('account restricted', { user: userId, reason, ...s });
    return reason;
  }

  return { issueChallenge, requirePow, checkSignupEmail, checkCanRequest, evaluate };
}
