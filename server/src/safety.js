// Blocking and abuse reports (see migrations/005_blocks_reports.sql).
import { timingSafeEqual } from 'node:crypto';

import { withTransaction } from './db.js';
import * as v from './validate.js';
import { HttpError, bad } from './validate.js';

export const REPORT_REASONS = ['spam', 'harassment', 'impersonation', 'illegal', 'other'];

/** SQL: does either of $a / $b block the other? */
export const BLOCKED_EITHER_WAY = `EXISTS (
  SELECT 1 FROM blocks
   WHERE (blocker_id = $a AND blocked_id = $b) OR (blocker_id = $b AND blocked_id = $a))`;

export async function isBlocked(pool, a, b) {
  const { rows } = await pool.query(
    `SELECT EXISTS (SELECT 1 FROM blocks
       WHERE (blocker_id = $1 AND blocked_id = $2) OR (blocker_id = $2 AND blocked_id = $1)) AS b`,
    [a, b],
  );
  return rows[0].b;
}

/** Did [blocker] block [blocked]? */
/**
 * SQL: had the account $2 dealt with $1 (a contact, or a request from $2)?
 * Only such reports and blocks count towards automatic restrictions.
 */
const RELATED_SQL = `(EXISTS (SELECT 1 FROM contacts WHERE owner_id = $1 AND contact_id = $2)
  OR EXISTS (SELECT 1 FROM contact_requests WHERE sender_id = $2 AND receiver_id = $1))`;

export async function hasBlocked(pool, blocker, blocked) {
  const { rows } = await pool.query('SELECT 1 FROM blocks WHERE blocker_id = $1 AND blocked_id = $2', [
    blocker,
    blocked,
  ]);
  return rows.length > 0;
}

/**
 * @param {import('./http.js').Router} router
 */
export function registerSafetyRoutes(router, { pool, hub, services, limits, config, antiSpam }) {
  const tooMany = () => new HttpError(429, 'rate_limited', 'Too many requests, slow down');

  /**
   * Blocks a user: removes the contact for both, drops pending requests in
   * both directions, and keeps them from finding or reaching you. They are
   * not told; they only see the contact go away.
   */
  router.add('POST', '/api/blocks', async ({ body, user }) => {
    v.requireObject(body);
    const target = v.uuid(body.user_id, 'user_id');
    if (target === user.id) throw bad('You cannot block yourself');
    const hadContact = await withTransaction(pool, async (client) => {
      const exists = await client.query('SELECT 1 FROM users WHERE id = $1', [target]);
      if (!exists.rows[0]) throw new HttpError(404, 'not_found', 'No such user');
      await client.query(
        `INSERT INTO blocks (blocker_id, blocked_id, related) VALUES ($1, $2, ${RELATED_SQL})
         ON CONFLICT DO NOTHING`,
        [user.id, target],
      );
      const removed = await client.query(
        `DELETE FROM contacts WHERE (owner_id = $1 AND contact_id = $2) OR (owner_id = $2 AND contact_id = $1)`,
        [user.id, target],
      );
      await client.query(
        `DELETE FROM contact_requests WHERE (sender_id = $1 AND receiver_id = $2) OR (sender_id = $2 AND receiver_id = $1)`,
        [user.id, target],
      );
      return removed.rowCount > 0;
    });
    await services.contactsChanged(user.id, target);
    await antiSpam.evaluate(target);
    if (hadContact) {
      hub.sendTo(target, { type: 'contact_removed', user_id: user.id });
      hub.sendTo(user.id, { type: 'contact_removed', user_id: target });
    }
    return { status: 201, body: { user_id: target, blocked: true } };
  });

  router.add('DELETE', '/api/blocks/:userId', async ({ params, user }) => {
    const target = v.uuid(params.userId, 'userId');
    await pool.query('DELETE FROM blocks WHERE blocker_id = $1 AND blocked_id = $2', [user.id, target]);
  });

  /** People you blocked, newest first. */
  router.add('GET', '/api/blocks', async ({ user }) => {
    const { rows } = await pool.query(
      `SELECT u.id, u.username, u.display_name, b.created_at
         FROM blocks b JOIN users u ON u.id = b.blocked_id
        WHERE b.blocker_id = $1 ORDER BY b.created_at DESC`,
      [user.id],
    );
    return rows.map((r) => ({
      user_id: r.id,
      username: r.username,
      display_name: r.display_name,
      blocked_at: r.created_at,
    }));
  });

  /**
   * Reports a user to the operator. [evidence] is optional: messages the
   * reporter decided to share (the server can't read any others).
   */
  router.add('POST', '/api/reports', async ({ body, user }) => {
    if (!(await limits.take('report', user.id))) throw tooMany();
    v.requireObject(body);
    const target = v.uuid(body.user_id, 'user_id');
    if (target === user.id) throw bad('You cannot report yourself');
    if (!REPORT_REASONS.includes(body.reason)) throw bad(`reason must be one of ${REPORT_REASONS.join(', ')}`);
    const details = body.details == null ? '' : v.string(body.details, 'details', { min: 0, max: 2000 });
    const evidence = body.evidence ?? [];
    if (!Array.isArray(evidence) || evidence.length > 20) throw bad('evidence must be at most 20 messages');
    const clean = evidence.map((e, i) => {
      if (e === null || typeof e !== 'object') throw bad(`evidence[${i}] must be an object`);
      return {
        from: e.from === 'reported' ? 'reported' : 'reporter',
        text: v.string(e.text ?? '', `evidence[${i}].text`, { min: 0, max: 4000 }),
        at: typeof e.at === 'string' ? e.at.slice(0, 40) : null,
      };
    });
    const { rows } = await pool.query(
      `INSERT INTO reports (reporter_id, reported_id, reason, details, evidence, related)
       SELECT $1, u.id, $3, $4, $5, ${RELATED_SQL} FROM users u WHERE u.id = $2 RETURNING id`,
      [user.id, target, body.reason, details, JSON.stringify(clean)],
    );
    if (!rows[0]) throw new HttpError(404, 'not_found', 'No such user');
    await antiSpam.evaluate(target);
    return { status: 201, body: { id: rows[0].id } };
  });

  // Operator: review reports with ADMIN_TOKEN (Authorization: Bearer <token>)

  function requireAdmin(req) {
    const expected = config.adminToken;
    const header = String(req.headers.authorization ?? '');
    const given = header.startsWith('Bearer ') ? header.slice(7) : '';
    const ok =
      expected &&
      expected.length >= 32 &&
      given.length === expected.length &&
      timingSafeEqual(Buffer.from(given), Buffer.from(expected));
    if (!ok) throw new HttpError(404, 'not_found');
  }

  router.add(
    'GET',
    '/api/admin/reports',
    async ({ req, query }) => {
      requireAdmin(req);
      const status = query.get('status') ?? 'open';
      const { rows } = await pool.query(
        `SELECT r.*, ru.username AS reporter_username, tu.username AS reported_username,
                (SELECT count(*)::int FROM reports x WHERE x.reported_id = r.reported_id) AS reports_against
           FROM reports r
           LEFT JOIN users ru ON ru.id = r.reporter_id
           LEFT JOIN users tu ON tu.id = r.reported_id
          WHERE r.status = $1 ORDER BY r.created_at LIMIT 200`,
        [status],
      );
      return rows;
    },
    { auth: false },
  );

  router.add(
    'POST',
    '/api/admin/reports/:id',
    async ({ req, params, body }) => {
      requireAdmin(req);
      v.requireObject(body);
      const id = v.uuid(params.id);
      if (!['resolved', 'dismissed'].includes(body.status)) throw bad("status must be 'resolved' or 'dismissed'");
      const { rowCount } = await pool.query('UPDATE reports SET status = $2, resolved_at = now() WHERE id = $1', [
        id,
        body.status,
      ]);
      if (!rowCount) throw new HttpError(404, 'not_found');
    },
    { auth: false },
  );

  /** Suspends an account: deletes its sessions (it can sign in again only after you remove the suspension). */
  router.add(
    'POST',
    '/api/admin/users/:id/suspend',
    async ({ req, params }) => {
      requireAdmin(req);
      const id = v.uuid(params.id);
      const revoked = await withTransaction(pool, async (client) => {
        const u = await client.query('UPDATE users SET suspended_at = now() WHERE id = $1 RETURNING id', [id]);
        if (!u.rows[0]) throw new HttpError(404, 'not_found');
        const s = await client.query('DELETE FROM sessions WHERE user_id = $1 RETURNING token_hash', [id]);
        return s.rows.map((r) => r.token_hash);
      });
      await services.revokeCachedSessions(revoked);
      hub.disconnectUser(id, 4003, 'account suspended');
    },
    { auth: false },
  );

  router.add(
    'DELETE',
    '/api/admin/users/:id/suspend',
    async ({ req, params }) => {
      requireAdmin(req);
      await pool.query('UPDATE users SET suspended_at = NULL WHERE id = $1', [v.uuid(params.id)]);
    },
    { auth: false },
  );

  /** Accounts restricted by the spam rules (src/spam.js). */
  router.add(
    'GET',
    '/api/admin/restricted',
    async ({ req }) => {
      requireAdmin(req);
      const { rows } = await pool.query(
        `SELECT id, username, display_name, created_at, restricted_until, restricted_reason
           FROM users WHERE restricted_until > now() ORDER BY restricted_until DESC LIMIT 200`,
      );
      return rows;
    },
    { auth: false },
  );

  router.add(
    'DELETE',
    '/api/admin/users/:id/restriction',
    async ({ req, params }) => {
      requireAdmin(req);
      await pool.query('UPDATE users SET restricted_until = NULL, restricted_reason = NULL WHERE id = $1', [
        v.uuid(params.id),
      ]);
    },
    { auth: false },
  );
}
