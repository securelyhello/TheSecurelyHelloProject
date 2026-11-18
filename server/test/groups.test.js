import assert from 'node:assert/strict';
import { randomBytes, randomUUID } from 'node:crypto';
import { after, before, describe, test } from 'node:test';

import { api, makeContacts, relaySend, signup, startServer } from './helpers.js';

let srv;
before(async () => {
  srv = await startServer();
});
after(() => srv.close());

const create = (who, members, groupId = randomUUID()) =>
  api(srv.base, 'POST', '/api/groups', { token: who.token, body: { group_id: groupId, members: members.map((m) => m.id) } });
const membersOf = (who, groupId) => api(srv.base, 'GET', `/api/groups/${groupId}`, { token: who.token });
const remove = (who, groupId, target) =>
  api(srv.base, 'DELETE', `/api/groups/${groupId}/members/${target.id}`, { token: who.token });
const claim = (who, target) =>
  api(srv.base, 'POST', `/api/users/${target.id}/prekey-bundles`, {
    token: who.token,
    body: { device_ids: [target.deviceId] },
  });

/** Alice with two contacts, Bob and Carol, who don't know each other. */
async function trio(tag) {
  const alice = await signup(srv.base, `g_${tag}_a`);
  const bob = await signup(srv.base, `g_${tag}_b`);
  const carol = await signup(srv.base, `g_${tag}_c`);
  await makeContacts(srv.base, alice, bob);
  await makeContacts(srv.base, alice, carol);
  return { alice, bob, carol };
}

describe('groups', () => {
  test('members who are not contacts can reach each other through the group', async () => {
    const { alice, bob, carol } = await trio('reach');
    assert.equal((await relaySend(srv.base, bob, carol)).status, 403, 'strangers before the group');
    assert.equal((await claim(bob, carol)).status, 403);

    const groupId = randomUUID();
    const made = await create(alice, [bob, carol], groupId);
    assert.equal(made.status, 201);
    assert.deepEqual(
      made.body.members.map((m) => [m.user_id, m.admin]),
      [
        [alice.id, true],
        [bob.id, false],
        [carol.id, false],
      ],
      'creator first and admin, then in the order given',
    );
    assert.equal(made.body.members[1].username, bob.username);

    assert.equal((await claim(bob, carol)).status, 200);
    assert.equal((await relaySend(srv.base, bob, carol)).status, 201);
    assert.equal((await relaySend(srv.base, carol, bob)).status, 201);

    // Attachments follow the same rule.
    const up = await fetch(`${srv.base}/api/attachments`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${bob.token}`, 'Content-Type': 'application/octet-stream' },
      body: randomBytes(500),
    }).then((r) => r.json());
    const got = await fetch(`${srv.base}/api/attachments/${up.id}`, { headers: { Authorization: `Bearer ${carol.token}` } });
    assert.equal(got.status, 200);
    await got.arrayBuffer();

    // A block in either direction cuts the group path, not the group.
    await api(srv.base, 'POST', '/api/blocks', { token: carol.token, body: { user_id: bob.id } });
    assert.equal((await relaySend(srv.base, bob, carol)).status, 403);
    assert.equal((await relaySend(srv.base, carol, bob)).status, 403);
    assert.equal((await relaySend(srv.base, alice, bob)).status, 201);
    await api(srv.base, 'DELETE', `/api/blocks/${bob.id}`, { token: carol.token });

    // Leaving ends it.
    assert.equal((await remove(carol, groupId, carol)).status, 204);
    assert.equal((await relaySend(srv.base, bob, carol)).status, 403);
    assert.equal((await membersOf(carol, groupId)).status, 404, 'no longer a member');
  });

  test('only admins add people, and only their own contacts', async () => {
    const { alice, bob, carol } = await trio('add');
    const stranger = await signup(srv.base, 'g_add_s');
    assert.equal((await create(alice, [bob, stranger])).status, 403, 'a stranger cannot be put in a group');
    assert.equal((await api(srv.base, 'GET', '/api/groups/' + randomUUID(), { token: alice.token })).status, 404);

    const groupId = randomUUID();
    assert.equal((await create(alice, [bob], groupId)).status, 201);
    assert.equal((await create(bob, [alice], groupId)).status, 409, 'the id is taken');

    const add = (who, target) =>
      api(srv.base, 'POST', `/api/groups/${groupId}/members`, { token: who.token, body: { user_ids: [target.id] } });
    assert.equal((await add(bob, carol)).status, 403, 'bob is not an admin');
    assert.equal((await add(alice, stranger)).status, 403, 'not her contact');
    assert.equal((await membersOf(stranger, groupId)).status, 404);
    const added = await add(alice, carol);
    assert.equal(added.status, 200);
    assert.deepEqual(added.body.members.map((m) => m.user_id), [alice.id, bob.id, carol.id]);
    assert.equal((await add(alice, carol)).status, 200, 'adding twice is harmless');

    assert.equal((await remove(bob, groupId, carol)).status, 403, 'members cannot remove others');
    assert.equal((await remove(alice, groupId, carol)).status, 204);
    assert.equal((await membersOf(carol, groupId)).status, 404);

    const bad = await api(srv.base, 'POST', '/api/groups', {
      token: alice.token,
      body: { group_id: randomUUID(), members: Array.from({ length: 64 }, () => randomUUID()) },
    });
    assert.equal(bad.status, 400, 'at most 63 others');
    const dup = await api(srv.base, 'POST', '/api/groups', {
      token: alice.token,
      body: { group_id: randomUUID(), members: [bob.id, bob.id] },
    });
    assert.equal(dup.status, 400);
  });

  test('a group always keeps an admin, and goes away with its last member', async () => {
    const { alice, bob, carol } = await trio('admin');
    const groupId = randomUUID();
    await create(alice, [bob, carol], groupId);

    const demote = await api(srv.base, 'PATCH', `/api/groups/${groupId}/members/${alice.id}`, {
      token: alice.token,
      body: { admin: false },
    });
    assert.equal(demote.status, 409, 'the last admin cannot step down');

    // The last admin leaving hands over to the longest-standing member.
    assert.equal((await remove(alice, groupId, alice)).status, 204);
    const left = await membersOf(bob, groupId);
    assert.deepEqual(left.body.members.map((m) => [m.user_id, m.admin]), [
      [bob.id, true],
      [carol.id, false],
    ]);

    const promote = await api(srv.base, 'PATCH', `/api/groups/${groupId}/members/${carol.id}`, {
      token: bob.token,
      body: { admin: true },
    });
    assert.equal(promote.status, 200);
    assert.ok(promote.body.members.every((m) => m.admin));

    await remove(bob, groupId, bob);
    await remove(carol, groupId, carol);
    const { rows } = await srv.pool.query('SELECT 1 FROM groups WHERE id = $1', [groupId]);
    assert.equal(rows.length, 0);
  });
});
