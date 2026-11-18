// One-time e-mail codes: 6 digits, stored hashed, short-lived, single use,
// at most CODE_MAX_ATTEMPTS guesses (right or wrong) per code.
//
// Every code e-mail goes through issueCode(), so this is where the global
// daily e-mail cap (EMAIL_DAILY_CAP, see ratelimit.js) is enforced.
import { createHash, randomInt, timingSafeEqual } from 'node:crypto';

import { codeEmail } from './mail.js';
import { HttpError } from './validate.js';

export const CODE_TTL_MINUTES = { verify: 30, reset: 15, device: 15 };
export const CODE_MAX_ATTEMPTS = 5;
const CODE_RE = /^\d{6}$/;

/** Thrown by issueCode() when the daily e-mail cap leaves no room. */
export const emailCapReached = () =>
  new HttpError(503, 'email_unavailable', 'E-mail is temporarily unavailable, try again later');

/** Global caps a code e-mail for [purpose] counts against. Verification
 * mail also has its own share, so it can't crowd out resets. */
const capsFor = (purpose) => (purpose === 'verify' ? ['emailDaily', 'emailVerifyDaily'] : ['emailDaily']);

/** @param {{pool: object, mailer: object, limits: import('./ratelimit.js').RateLimits}} deps */
export function createCodes({ pool, mailer, limits }) {
  const codeHash = (userId, purpose, code) =>
    createHash('sha256').update(`securelyhello-code|${purpose}|${userId}|${code}`).digest();

  /**
   * Whether the daily cap has room for one [purpose] e-mail, without using
   * any. Lets callers refuse before spending a user's own budget; racy, so
   * issueCode() checks again for real.
   */
  async function canSend(purpose) {
    return limits.peekAll(capsFor(purpose), 'global');
  }

  /**
   * Creates (or replaces) a code for [purpose] and e-mails it. Throws
   * emailCapReached() (503) when the daily cap is used up; nothing is stored
   * or sent then.
   */
  async function issueCode(userId, email, purpose) {
    // One atomic take across every cap: either all get a slot or none does,
    // so a full overall cap never burns a verification slot (or vice versa),
    // even under concurrent requests.
    if (!(await limits.takeAll(capsFor(purpose), 'global'))) throw emailCapReached();
    const code = String(randomInt(0, 1_000_000)).padStart(6, '0');
    const minutes = CODE_TTL_MINUTES[purpose];
    await pool.query(
      `INSERT INTO email_codes (user_id, purpose, code_hash, expires_at)
       VALUES ($1, $2, $3, now() + make_interval(mins => $4))
       ON CONFLICT (user_id, purpose) DO UPDATE
         SET code_hash = EXCLUDED.code_hash, attempts = 0, created_at = now(), expires_at = EXCLUDED.expires_at`,
      [userId, purpose, codeHash(userId, purpose, code), minutes],
    );
    await mailer.send(codeEmail(purpose, email, code, minutes));
  }

  /**
   * Spends one attempt on the live code; consumes it if [code] matches,
   * unless [keep] (the caller still needs a second factor before acting).
   */
  async function consumeCode(userId, purpose, code, { keep = false } = {}) {
    if (typeof code !== 'string' || !CODE_RE.test(code)) return false;
    const { rows } = await pool.query(
      `UPDATE email_codes SET attempts = attempts + 1
        WHERE user_id = $1 AND purpose = $2 AND expires_at > now() AND attempts < $3
        RETURNING code_hash`,
      [userId, purpose, CODE_MAX_ATTEMPTS],
    );
    if (!rows[0]) return false;
    const expected = rows[0].code_hash;
    const given = codeHash(userId, purpose, code);
    if (expected.length !== given.length || !timingSafeEqual(expected, given)) return false;
    if (keep) {
      // Give back the attempt: a right code shouldn't count against the user.
      await pool.query('UPDATE email_codes SET attempts = attempts - 1 WHERE user_id = $1 AND purpose = $2', [
        userId,
        purpose,
      ]);
      return true;
    }
    const del = await pool.query('DELETE FROM email_codes WHERE user_id = $1 AND purpose = $2 AND code_hash = $3', [
      userId,
      purpose,
      given,
    ]);
    return del.rowCount === 1;
  }

  return { canSend, issueCode, consumeCode };
}
