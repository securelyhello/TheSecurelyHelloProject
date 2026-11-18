// Invite links and opt-in contact discovery.
//
// Invites: POST /api/invites makes a link token (random, stored hashed).
// Whoever opens it sees the inviter and can accept, which makes them
// contacts directly. Links expire, have a use limit and can be revoked.
//
// Discovery: the app sends SHA-256 hashes of e-mail addresses from the
// phone's address book; the server answers with the accounts that opted
// in (email_discoverable). Hashing alone doesn't hide an address from
// someone who guesses it, so lookups are rate-limited per account and only
// opted-in users can ever match.
import { createHash, randomBytes } from 'node:crypto';

import { withTransaction } from './db.js';
import { hasBlocked } from './safety.js';
import * as v from './validate.js';
import { HttpError, bad } from './validate.js';

export const emailHash = (email) =>
  createHash('sha256').update(`securelyhello-email|${email.toLowerCase()}`).digest();

const tokenHash = (token) => createHash('sha256').update(`securelyhello-invite|${token}`).digest();
const INVITE_DAYS = 30;
const INVITE_USES = 25;
const MAX_HASHES = 500;
const TOKEN_RE = /^[A-Za-z0-9_-]{22}$/;

export function registerInviteRoutes(router, { pool, hub, services, limits, config, antiSpam }) {
  async function limit(name, key) {
    if (!(await limits.take(name, key))) throw new HttpError(429, 'rate_limited', 'Too many requests, slow down');
  }

  const inviteUrl = (token) => `${config.inviteBaseUrl}${token}`;

  async function isVerified(client, userId) {
    const { rows } = await client.query('SELECT email_verified_at FROM users WHERE id = $1', [userId]);
    return rows[0]?.email_verified_at != null;
  }
  const unverified = () => new HttpError(403, 'email_unverified', 'Verify your e-mail address first');

  router.add('POST', '/api/invites', async ({ user }) => {
    await limit('invite', user.id);
    if (config.emailVerification === 'required' && !(await isVerified(pool, user.id))) throw unverified();
    await antiSpam.checkCanRequest(user.id);
    const token = randomBytes(16).toString('base64url');
    await pool.query(
      `INSERT INTO invites (token_hash, inviter_id, expires_at, max_uses)
       VALUES ($1, $2, now() + make_interval(days => $3), $4)`,
      [tokenHash(token), user.id, INVITE_DAYS, INVITE_USES],
    );
    return { status: 201, body: { token, url: inviteUrl(token), expires_in_days: INVITE_DAYS, max_uses: INVITE_USES } };
  });

  /** Revokes every open invite of this account. */
  router.add('DELETE', '/api/invites', async ({ user }) => {
    const { rowCount } = await pool.query(
      'UPDATE invites SET revoked_at = now() WHERE inviter_id = $1 AND revoked_at IS NULL',
      [user.id],
    );
    return { revoked: rowCount };
  });

  async function openInvite(client, token, { lock = false } = {}) {
    if (typeof token !== 'string' || !TOKEN_RE.test(token)) throw new HttpError(404, 'invite_invalid', 'This invite link is not valid');
    const { rows } = await client.query(
      `SELECT i.inviter_id, u.username, u.display_name, u.suspended_at
         FROM invites i JOIN users u ON u.id = i.inviter_id
        WHERE i.token_hash = $1 AND i.revoked_at IS NULL AND i.expires_at > now() AND i.uses < i.max_uses
        ${lock ? 'FOR UPDATE OF i' : ''}`,
      [tokenHash(token)],
    );
    const row = rows[0];
    if (!row || row.suspended_at) throw new HttpError(404, 'invite_invalid', 'This invite link has expired or was revoked');
    return row;
  }

  /** Who sent this invite (shown before accepting). */
  router.add('GET', '/api/invites/:token', async ({ params, user }) => {
    await limit('inviteLookup', user.id);
    const row = await openInvite(pool, params.token);
    if (row.inviter_id !== user.id && (await hasBlocked(pool, row.inviter_id, user.id))) {
      throw new HttpError(404, 'invite_invalid', 'This invite link has expired or was revoked');
    }
    const contacts = new Set(await services.contactIds(user.id));
    return {
      inviter: { user_id: row.inviter_id, username: row.username, display_name: row.display_name },
      own: row.inviter_id === user.id,
      already_contacts: contacts.has(row.inviter_id),
    };
  });

  router.add('POST', '/api/invites/:token/accept', async ({ params, user }) => {
    await limit('inviteLookup', user.id);
    if (config.emailVerification === 'required') {
      const { rows } = await pool.query('SELECT email_verified_at FROM users WHERE id = $1', [user.id]);
      if (!rows[0]?.email_verified_at) throw new HttpError(403, 'email_unverified', 'Verify your e-mail address first');
    }
    const inviterId = await withTransaction(pool, async (client) => {
      const row = await openInvite(client, params.token, { lock: true });
      if (row.inviter_id === user.id) throw bad('This is your own invite', 'own_invite');
      if (config.emailVerification === 'required' && !(await isVerified(client, row.inviter_id))) {
        throw new HttpError(404, 'invite_invalid', 'This invite link has expired or was revoked');
      }
      // Either side's block wins, silently for the inviter.
      if ((await hasBlocked(client, row.inviter_id, user.id)) || (await hasBlocked(client, user.id, row.inviter_id))) {
        throw new HttpError(404, 'invite_invalid', 'This invite link has expired or was revoked');
      }
      const added = await client.query(
        `INSERT INTO contacts (owner_id, contact_id) VALUES ($1, $2), ($2, $1) ON CONFLICT DO NOTHING`,
        [row.inviter_id, user.id],
      );
      if (added.rowCount > 0) {
        await client.query('UPDATE invites SET uses = uses + 1 WHERE token_hash = $1', [tokenHash(params.token)]);
        // Any pending request between the two is settled by this.
        await client.query(
          `UPDATE contact_requests SET status = 'accepted', updated_at = now()
            WHERE status = 'pending' AND ((sender_id = $1 AND receiver_id = $2) OR (sender_id = $2 AND receiver_id = $1))`,
          [row.inviter_id, user.id],
        );
      }
      return row.inviter_id;
    });
    await services.contactsChanged(inviterId, user.id);
    hub.sendTo(inviterId, { type: 'contact_added', user_id: user.id, via: 'invite' });
    hub.sendTo(user.id, { type: 'contact_added', user_id: inviterId, via: 'invite' });
    return { contact_user_id: inviterId };
  });

  // ---- discovery ----

  router.add('PUT', '/api/me/discovery', async ({ body, user }) => {
    v.requireObject(body);
    if (typeof body.email_discoverable !== 'boolean') throw bad('email_discoverable must be true or false');
    if (body.email_discoverable) {
      // Otherwise anyone could claim an address and appear under its owner's name.
      const { rows } = await pool.query('SELECT email_verified_at FROM users WHERE id = $1', [user.id]);
      if (!rows[0]?.email_verified_at) {
        throw new HttpError(403, 'email_unverified', 'Verify your e-mail address before letting people find you by it');
      }
    }
    await pool.query('UPDATE users SET email_discoverable = $2 WHERE id = $1', [user.id, body.email_discoverable]);
    return { email_discoverable: body.email_discoverable };
  });

  router.add('GET', '/api/me/discovery', async ({ user }) => {
    const { rows } = await pool.query('SELECT email_discoverable FROM users WHERE id = $1', [user.id]);
    return { email_discoverable: rows[0]?.email_discoverable === true };
  });

  /**
   * Matches address-book hashes against opted-in accounts. Returns profiles
   * (never e-mail addresses) and which hash matched, so the app can show the
   * name from the address book next to it.
   */
  router.add('POST', '/api/discovery/match', async ({ body, user }) => {
    await limit('discovery', user.id);
    v.requireObject(body);
    if (!Array.isArray(body.hashes) || body.hashes.length > MAX_HASHES) {
      throw bad(`hashes must be a list of at most ${MAX_HASHES}`);
    }
    const hashes = [];
    for (const h of body.hashes) {
      const buf = typeof h === 'string' ? Buffer.from(h, 'base64') : null;
      if (!buf || buf.length !== 32) throw bad('Each hash must be 32 bytes, base64');
      hashes.push(buf);
    }
    if (hashes.length === 0) return [];
    const { rows } = await pool.query(
      `SELECT u.id, u.username, u.display_name, u.email_hash,
              EXISTS (SELECT 1 FROM contacts c WHERE c.owner_id = $2 AND c.contact_id = u.id) AS is_contact
         FROM users u
        WHERE u.email_discoverable AND u.email_verified_at IS NOT NULL
          AND u.email_hash = ANY($1::bytea[]) AND u.id <> $2
          AND u.suspended_at IS NULL
          AND NOT EXISTS (SELECT 1 FROM blocks b
                           WHERE (b.blocker_id = u.id AND b.blocked_id = $2) OR (b.blocker_id = $2 AND b.blocked_id = u.id))
        LIMIT $3`,
      [hashes, user.id, MAX_HASHES],
    );
    return rows.map((r) => ({
      hash: r.email_hash.toString('base64'),
      user: { user_id: r.id, username: r.username, display_name: r.display_name },
      is_contact: r.is_contact,
    }));
  });
}
