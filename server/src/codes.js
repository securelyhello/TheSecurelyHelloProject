// One-time e-mail codes: 6 digits, stored hashed, short-lived, single use,
// at most CODE_MAX_ATTEMPTS guesses (right or wrong) per code.
import { createHash, randomInt, timingSafeEqual } from 'node:crypto';

import { codeEmail } from './mail.js';

export const CODE_TTL_MINUTES = { verify: 30, reset: 15, device: 15 };
export const CODE_MAX_ATTEMPTS = 5;
const CODE_RE = /^\d{6}$/;

export function createCodes({ pool, mailer }) {
  const codeHash = (userId, purpose, code) =>
    createHash('sha256').update(`securelyhello-code|${purpose}|${userId}|${code}`).digest();

  /** Creates (or replaces) a code for [purpose] and e-mails it. */
  async function issueCode(userId, email, purpose) {
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

  /** Spends one attempt on the live code; consumes it if [code] matches. */
  async function consumeCode(userId, purpose, code) {
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
    const del = await pool.query('DELETE FROM email_codes WHERE user_id = $1 AND purpose = $2 AND code_hash = $3', [
      userId,
      purpose,
      given,
    ]);
    return del.rowCount === 1;
  }

  return { issueCode, consumeCode };
}
