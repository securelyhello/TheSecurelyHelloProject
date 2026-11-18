// Group membership, kept for abuse control only.
//
// A group's name and messages travel end to end between its members, who
// also keep the authoritative member list (the app's group state, signed
// by an admin's session). The server keeps its own copy of who is in which
// group so that members who aren't each other's contacts may claim prekeys
// and relay to each other, and so that only admins add people, and only
// their own contacts. Nobody can be put in a group by a stranger.
import { withTransaction } from './db.js';
import * as v from './validate.js';
import { HttpError, bad } from './validate.js';

export const MAX_GROUP_MEMBERS = 64;

const notFound = () => new HttpError(404, 'not_found', 'No such group');

export function registerGroupRoutes(router, { pool, services, limits }) {
  async function limit(key) {
    if (!(await limits.take('groupChange', key))) throw new HttpError(429, 'rate_limited', 'Too many requests, slow down');
  }

  async function memberRow(client, groupId, userId) {
    const { rows } = await client.query('SELECT admin FROM group_members WHERE group_id = $1 AND user_id = $2', [
      groupId,
      userId,
    ]);
    return rows[0] ?? null;
  }

  async function requireAdmin(client, groupId, userId) {
    const row = await memberRow(client, groupId, userId);
    if (!row) throw notFound();
    if (!row.admin) throw new HttpError(403, 'not_admin', 'Only group admins can do that');
  }

  /** Only your own contacts can be added. */
  async function requireContacts(adder, ids) {
    for (const id of ids) {
      if (!(await services.areContacts(adder, id))) {
        throw new HttpError(403, 'not_contacts', 'You can only add your contacts to a group');
      }
    }
  }

  function userIds(list, what) {
    if (!Array.isArray(list) || list.length === 0 || list.length >= MAX_GROUP_MEMBERS || !list.every(v.isUuid)) {
      throw bad(`${what} must be 1-${MAX_GROUP_MEMBERS - 1} user ids`);
    }
    const ids = list.map((x) => x.toLowerCase());
    if (new Set(ids).size !== ids.length) throw bad(`${what} has duplicates`);
    return ids;
  }

  async function members(client, groupId) {
    const { rows } = await client.query(
      `SELECT m.user_id, m.admin, u.username, u.display_name
         FROM group_members m JOIN users u ON u.id = m.user_id
        WHERE m.group_id = $1 ORDER BY m.seq`,
      [groupId],
    );
    return rows;
  }

  /** Keeps at least one admin: the longest-standing member takes over. */
  async function ensureAdmin(client, groupId) {
    const { rows } = await client.query('SELECT 1 FROM group_members WHERE group_id = $1 AND admin', [groupId]);
    if (rows.length > 0) return;
    await client.query(
      `UPDATE group_members SET admin = true
        WHERE group_id = $1 AND user_id = (SELECT user_id FROM group_members WHERE group_id = $1 ORDER BY seq LIMIT 1)`,
      [groupId],
    );
  }

  router.add('POST', '/api/groups', async ({ body, user }) => {
    v.requireObject(body);
    const groupId = v.uuid(body.group_id, 'group_id');
    const ids = userIds(body.members, 'members');
    if (ids.includes(user.id)) throw bad('members must not include yourself');
    await limit(user.id);
    await requireContacts(user.id, ids);
    await withTransaction(pool, async (client) => {
      const made = await client.query('INSERT INTO groups (id, created_by) VALUES ($1, $2) ON CONFLICT DO NOTHING', [
        groupId,
        user.id,
      ]);
      if (made.rowCount === 0) throw new HttpError(409, 'group_exists', 'That group id is taken');
      await client.query('INSERT INTO group_members (group_id, user_id, admin) VALUES ($1, $2, true)', [groupId, user.id]);
      for (const id of ids) {
        await client.query('INSERT INTO group_members (group_id, user_id) VALUES ($1, $2)', [groupId, id]);
      }
    });
    return { status: 201, body: { group_id: groupId, members: await members(pool, groupId) } };
  });

  /** Members, with their public names, for members only. */
  router.add('GET', '/api/groups/:id', async ({ params, user }) => {
    const groupId = v.uuid(params.id);
    if (!(await memberRow(pool, groupId, user.id))) throw notFound();
    return { group_id: groupId, members: await members(pool, groupId) };
  });

  router.add('POST', '/api/groups/:id/members', async ({ params, body, user }) => {
    const groupId = v.uuid(params.id);
    v.requireObject(body);
    const ids = userIds(body.user_ids, 'user_ids');
    await limit(user.id);
    await requireAdmin(pool, groupId, user.id);
    await requireContacts(user.id, ids.filter((id) => id !== user.id));
    await withTransaction(pool, async (client) => {
      await client.query('SELECT 1 FROM groups WHERE id = $1 FOR UPDATE', [groupId]);
      for (const id of ids) {
        await client.query('INSERT INTO group_members (group_id, user_id) VALUES ($1, $2) ON CONFLICT DO NOTHING', [
          groupId,
          id,
        ]);
      }
      const { rows } = await client.query('SELECT count(*)::int AS n FROM group_members WHERE group_id = $1', [groupId]);
      if (rows[0].n > MAX_GROUP_MEMBERS) {
        throw new HttpError(409, 'group_full', `A group can have up to ${MAX_GROUP_MEMBERS} members`);
      }
    });
    return { group_id: groupId, members: await members(pool, groupId) };
  });

  /** An admin removes someone, or a member leaves. */
  router.add('DELETE', '/api/groups/:id/members/:userId', async ({ params, user }) => {
    const groupId = v.uuid(params.id);
    const target = v.uuid(params.userId);
    await limit(user.id);
    if (target === user.id) {
      if (!(await memberRow(pool, groupId, user.id))) throw notFound();
    } else {
      await requireAdmin(pool, groupId, user.id);
    }
    await withTransaction(pool, async (client) => {
      await client.query('SELECT 1 FROM groups WHERE id = $1 FOR UPDATE', [groupId]);
      await client.query('DELETE FROM group_members WHERE group_id = $1 AND user_id = $2', [groupId, target]);
      const { rows } = await client.query('SELECT 1 FROM group_members WHERE group_id = $1 LIMIT 1', [groupId]);
      if (rows.length === 0) {
        await client.query('DELETE FROM groups WHERE id = $1', [groupId]);
      } else {
        await ensureAdmin(client, groupId);
      }
    });
  });

  router.add('PATCH', '/api/groups/:id/members/:userId', async ({ params, body, user }) => {
    const groupId = v.uuid(params.id);
    const target = v.uuid(params.userId);
    v.requireObject(body);
    if (typeof body.admin !== 'boolean') throw bad('admin must be true or false');
    await limit(user.id);
    await requireAdmin(pool, groupId, user.id);
    await withTransaction(pool, async (client) => {
      await client.query('SELECT 1 FROM groups WHERE id = $1 FOR UPDATE', [groupId]);
      const updated = await client.query('UPDATE group_members SET admin = $3 WHERE group_id = $1 AND user_id = $2', [
        groupId,
        target,
        body.admin,
      ]);
      if (updated.rowCount === 0) throw notFound();
      const { rows } = await client.query('SELECT 1 FROM group_members WHERE group_id = $1 AND admin', [groupId]);
      if (rows.length === 0) throw new HttpError(409, 'last_admin', 'A group needs at least one admin');
    });
    return { group_id: groupId, members: await members(pool, groupId) };
  });
}
