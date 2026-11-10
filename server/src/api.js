// HTTP API. Everything lives under /api/ (the edge proxy only lets
// non-browser clients through on that prefix). All JSON. Every route needs a
// Bearer session token unless registered with {auth:false}. The acting user
// is always taken from the session, never from the request body.
import { withTransaction } from './db.js';
import { burnPasswordCheck, hashPassword, hashToken, newSessionToken, verifyPassword } from './security.js';
import * as v from './validate.js';
import { HttpError, bad } from './validate.js';

const notFound = (what = 'Not found') => new HttpError(404, 'not_found', what);
const tooMany = () => new HttpError(429, 'rate_limited', 'Too many requests, slow down');

const USER_COLUMNS =
  'u.id, u.email, u.username, u.display_name, u.signing_public_key, u.encryption_public_key, u.created_at';

/**
 * @param {import('./http.js').Router} router
 * @param {object} deps
 * @param {import('pg').Pool} deps.pool
 * @param {import('./realtime.js').RealtimeHub} deps.hub
 * @param {import('./hotstore.js').HotStore} deps.store
 * @param {import('./services.js').Services} deps.services
 * @param {import('./ratelimit.js').RateLimits} deps.limits
 */
export function registerRoutes(router, { pool, hub, store, services, limits, config }) {
  // ---------------------------------------------------------------------------
  // Serialization
  // ---------------------------------------------------------------------------

  /** Public profile. Presence is only revealed to contacts (and yourself). */
  const profile = (row, presence = null) => ({
    user_id: row.id,
    username: row.username,
    display_name: row.display_name,
    signing_public_key: row.signing_public_key,
    encryption_public_key: row.encryption_public_key,
    status: presence ? (presence.online ? 'online' : 'offline') : null,
    last_seen: presence ? presence.last_seen : null,
  });

  /** Serializes rows, attaching presence for ids in [visible]. */
  async function profiles(rows, visible) {
    const ids = rows.map((r) => r.id).filter((id) => visible.has(id));
    const pres = await services.presence(ids);
    return rows.map((r) => profile(r, pres.get(r.id) ?? null));
  }

  async function me(row) {
    const pres = await services.presence([row.id]);
    return { ...profile(row, pres.get(row.id)), email: row.email, created_at: row.created_at };
  }

  async function createSession(client, userId) {
    const token = newSessionToken();
    await client.query(
      `INSERT INTO sessions (token_hash, user_id, expires_at)
       VALUES ($1, $2, now() + make_interval(days => $3))`,
      [hashToken(token), userId, config.sessionTtlDays],
    );
    return token;
  }

  async function limit(name, key) {
    if (!(await limits.take(name, key))) throw tooMany();
  }

  // ---------------------------------------------------------------------------
  // Health
  // ---------------------------------------------------------------------------

  const health = async () => {
    const timeout = (ms) => new Promise((_, rej) => setTimeout(() => rej(new Error('timeout')), ms).unref());
    const [pg, redis] = await Promise.allSettled([
      Promise.race([pool.query('SELECT 1'), timeout(3000)]),
      Promise.race([store.ping(), timeout(3000)]),
    ]);
    const body = {
      ok: pg.status === 'fulfilled' && redis.status === 'fulfilled' && redis.value === true,
      postgres: pg.status === 'fulfilled',
      redis: redis.status === 'fulfilled' && redis.value === true,
    };
    return { status: body.ok ? 200 : 503, body };
  };
  router.add('GET', '/healthz', health, { auth: false });
  router.add('GET', '/api/healthz', health, { auth: false });

  // ---------------------------------------------------------------------------
  // Auth
  // ---------------------------------------------------------------------------

  router.add(
    'POST',
    '/api/auth/signup',
    async ({ body, ip }) => {
      await limit('authIp', ip);
      v.requireObject(body);
      const email = v.email(body.email);
      const password = v.password(body.password);
      const username = v.username(body.username);
      const displayName = v.displayName(body.display_name ?? body.username);
      const signingKey = v.publicKey(body.signing_public_key, 'signing_public_key');
      const encryptionKey = v.publicKey(body.encryption_public_key, 'encryption_public_key');
      const passwordHash = await hashPassword(password);

      try {
        const { row, token } = await withTransaction(pool, async (client) => {
          const { rows } = await client.query(
            `INSERT INTO users AS u (email, username, display_name, password_hash,
                                     signing_public_key, encryption_public_key)
             VALUES ($1, $2, $3, $4, $5, $6)
             RETURNING ${USER_COLUMNS}`,
            [email, username, displayName, passwordHash, signingKey, encryptionKey],
          );
          return { row: rows[0], token: await createSession(client, rows[0].id) };
        });
        return { status: 201, body: { token, user: await me(row) } };
      } catch (err) {
        if (err.code === '23505') {
          if (String(err.constraint).includes('username')) {
            throw new HttpError(409, 'username_taken', `@${username} is already taken`);
          }
          throw new HttpError(409, 'email_taken', 'An account with this email already exists');
        }
        throw err;
      }
    },
    { auth: false },
  );

  router.add(
    'POST',
    '/api/auth/signin',
    async ({ body, ip }) => {
      await limit('authIp', ip);
      v.requireObject(body);
      const email = v.email(body.email);
      if (typeof body.password !== 'string' || body.password.length > 256) {
        throw bad('password is required');
      }
      await limit('authAccount', email.toLowerCase());

      const { rows } = await pool.query(
        `SELECT ${USER_COLUMNS}, u.password_hash FROM users u WHERE lower(u.email) = lower($1)`,
        [email],
      );
      const row = rows[0];
      if (!row) {
        await burnPasswordCheck(body.password);
        throw new HttpError(401, 'invalid_credentials', 'Wrong email or password');
      }
      if (!(await verifyPassword(body.password, row.password_hash))) {
        throw new HttpError(401, 'invalid_credentials', 'Wrong email or password');
      }
      const token = await createSession(pool, row.id);
      return { token, user: await me(row) };
    },
    { auth: false },
  );

  // The client closes its own WebSocket; a revoked token cannot open another.
  router.add('POST', '/api/auth/signout', async ({ token }) => {
    const hash = hashToken(token);
    await pool.query('DELETE FROM sessions WHERE token_hash = $1', [hash]);
    await services.revokeCachedSessions([hash]);
  });

  router.add('POST', '/api/auth/change-password', async ({ body, user, token }) => {
    await limit('authAccount', `pw:${user.id}`);
    v.requireObject(body);
    if (typeof body.current_password !== 'string' || body.current_password.length > 256) {
      throw bad('current_password is required');
    }
    const next = v.password(body.new_password, 'new_password');
    const { rows } = await pool.query('SELECT password_hash FROM users WHERE id = $1', [user.id]);
    if (!rows[0] || !(await verifyPassword(body.current_password, rows[0].password_hash))) {
      throw new HttpError(403, 'invalid_credentials', 'Current password is wrong');
    }
    const hash = await hashPassword(next);
    const revoked = await withTransaction(pool, async (client) => {
      await client.query('UPDATE users SET password_hash = $2, updated_at = now() WHERE id = $1', [user.id, hash]);
      // Revoke every other session; keep the one making this request.
      const res = await client.query(
        'DELETE FROM sessions WHERE user_id = $1 AND token_hash <> $2 RETURNING token_hash',
        [user.id, hashToken(token)],
      );
      return res.rows.map((r) => r.token_hash);
    });
    await services.revokeCachedSessions(revoked);
  });

  router.add(
    'GET',
    '/api/usernames/:username/available',
    async ({ params, ip }) => {
      await limit('publicIp', ip);
      const username = v.username(params.username);
      const { rows } = await pool.query('SELECT 1 FROM users WHERE username = $1', [username]);
      return { username, available: rows.length === 0 };
    },
    { auth: false },
  );

  // ---------------------------------------------------------------------------
  // Me
  // ---------------------------------------------------------------------------

  router.add('GET', '/api/me', async ({ user }) => {
    const { rows } = await pool.query(`SELECT ${USER_COLUMNS} FROM users u WHERE u.id = $1`, [user.id]);
    if (!rows[0]) throw notFound();
    return me(rows[0]);
  });

  router.add('PATCH', '/api/me', async ({ body, user }) => {
    v.requireObject(body);
    const sets = [];
    const args = [user.id];
    if (body.display_name !== undefined) {
      args.push(v.displayName(body.display_name));
      sets.push(`display_name = $${args.length}`);
    }
    if (body.username !== undefined) {
      args.push(v.username(body.username));
      sets.push(`username = $${args.length}`);
    }
    if (sets.length === 0) throw bad('Nothing to update');
    try {
      const { rows } = await pool.query(
        `UPDATE users u SET ${sets.join(', ')}, updated_at = now() WHERE u.id = $1 RETURNING ${USER_COLUMNS}`,
        args,
      );
      return me(rows[0]);
    } catch (err) {
      if (err.code === '23505') throw new HttpError(409, 'username_taken', 'That username is already taken');
      throw err;
    }
  });

  router.add('PUT', '/api/me/keys', async ({ body, user }) => {
    v.requireObject(body);
    const signingKey = v.publicKey(body.signing_public_key, 'signing_public_key');
    const encryptionKey = v.publicKey(body.encryption_public_key, 'encryption_public_key');
    const { rows } = await pool.query(
      `UPDATE users u SET signing_public_key = $2, encryption_public_key = $3, updated_at = now()
        WHERE u.id = $1 RETURNING ${USER_COLUMNS}`,
      [user.id, signingKey, encryptionKey],
    );
    for (const id of await services.contactIds(user.id)) {
      hub.sendTo(id, { type: 'keys_changed', user_id: user.id });
    }
    return me(rows[0]);
  });

  router.add('DELETE', '/api/me', async ({ user }) => {
    const contacts = await services.contactIds(user.id);
    // ON DELETE CASCADE removes sessions, requests and contacts.
    const sessions = await withTransaction(pool, async (client) => {
      const res = await client.query('SELECT token_hash FROM sessions WHERE user_id = $1', [user.id]);
      await client.query('DELETE FROM users WHERE id = $1', [user.id]);
      return res.rows.map((r) => r.token_hash);
    });
    await services.revokeCachedSessions(sessions);
    await services.contactsChanged(user.id, ...contacts);
    await store.relayPurgeUser(user.id);
    await store.forgetPresence(user.id);
    for (const id of contacts) hub.sendTo(id, { type: 'contact_removed', user_id: user.id });
    hub.disconnectUser(user.id, 4003, 'account deleted');
  });

  // ---------------------------------------------------------------------------
  // Directory
  // ---------------------------------------------------------------------------

  router.add('GET', '/api/users/search', async ({ query, user }) => {
    const q = (query.get('q') ?? '').trim().toLowerCase().replace(/^@/, '');
    if (q.length < 1 || q.length > 30) throw bad('q must be 1-30 characters');
    const { rows } = await pool.query(
      `SELECT ${USER_COLUMNS} FROM users u
        WHERE u.username LIKE '%' || $1 || '%' ESCAPE '\\' AND u.id <> $2
        ORDER BY (u.username = $3) DESC, (u.username LIKE $1 || '%' ESCAPE '\\') DESC, u.username
        LIMIT 20`,
      [v.escapeLike(q), user.id, q],
    );
    return profiles(rows, new Set(await services.contactIds(user.id)));
  });

  async function lookup(user, where, arg) {
    const { rows } = await pool.query(`SELECT ${USER_COLUMNS} FROM users u WHERE ${where}`, [arg]);
    if (!rows[0]) throw notFound('No such user');
    const visible = new Set(await services.contactIds(user.id));
    visible.add(user.id);
    return (await profiles(rows, visible))[0];
  }

  router.add('GET', '/api/users/by-username/:username', ({ params, user }) =>
    lookup(user, 'u.username = $1', v.username(params.username)),
  );

  router.add('GET', '/api/users/:id', ({ params, user }) => lookup(user, 'u.id = $1', v.uuid(params.id)));

  // ---------------------------------------------------------------------------
  // Contact requests
  // ---------------------------------------------------------------------------

  const requestSelect = `
    SELECT r.id, r.sender_id, r.receiver_id, r.status, r.created_at, r.updated_at,
           s.id AS s_id, s.username AS s_username, s.display_name AS s_display_name,
           s.signing_public_key AS s_signing_public_key, s.encryption_public_key AS s_encryption_public_key,
           t.id AS t_id, t.username AS t_username, t.display_name AS t_display_name,
           t.signing_public_key AS t_signing_public_key, t.encryption_public_key AS t_encryption_public_key
      FROM contact_requests r
      JOIN users s ON s.id = r.sender_id
      JOIN users t ON t.id = r.receiver_id`;

  const pick = (row, prefix) => ({
    id: row[`${prefix}_id`],
    username: row[`${prefix}_username`],
    display_name: row[`${prefix}_display_name`],
    signing_public_key: row[`${prefix}_signing_public_key`],
    encryption_public_key: row[`${prefix}_encryption_public_key`],
  });

  const requestJson = (row) => ({
    id: row.id,
    sender_user_id: row.sender_id,
    receiver_user_id: row.receiver_id,
    status: row.status,
    created_at: row.created_at,
    updated_at: row.updated_at,
    sender: profile(pick(row, 's')),
    receiver: profile(pick(row, 't')),
  });

  async function loadRequest(id) {
    const { rows } = await pool.query(`${requestSelect} WHERE r.id = $1`, [id]);
    return rows[0] ? requestJson(rows[0]) : null;
  }

  async function makeContacts(client, a, b) {
    await client.query(
      `INSERT INTO contacts (owner_id, contact_id) VALUES ($1, $2), ($2, $1)
       ON CONFLICT DO NOTHING`,
      [a, b],
    );
  }

  /** After an acceptance, tell each side whether the other is online. */
  async function becameContacts(a, b) {
    await services.contactsChanged(a, b);
    const pres = await services.presence([a, b]);
    hub.sendTo(a, { type: 'presence', user_id: b, ...pres.get(b) });
    hub.sendTo(b, { type: 'presence', user_id: a, ...pres.get(a) });
  }

  router.add('GET', '/api/contact-requests', async ({ user }) => {
    const { rows } = await pool.query(
      `${requestSelect}
        WHERE r.status = 'pending' AND (r.sender_id = $1 OR r.receiver_id = $1)
        ORDER BY r.created_at DESC
        LIMIT 500`,
      [user.id],
    );
    return rows.map(requestJson);
  });

  router.add('POST', '/api/contact-requests', async ({ body, user }) => {
    await limit('contactRequest', user.id);
    v.requireObject(body);
    let receiverId;
    if (body.receiver_id !== undefined) {
      receiverId = v.uuid(body.receiver_id, 'receiver_id');
    } else if (body.username !== undefined) {
      const { rows } = await pool.query('SELECT id FROM users WHERE username = $1', [v.username(body.username)]);
      if (!rows[0]) throw notFound('No such user');
      receiverId = rows[0].id;
    } else {
      throw bad('receiver_id or username is required');
    }
    if (receiverId === user.id) throw bad('You cannot add yourself', 'self_request');

    const outcome = await withTransaction(pool, async (client) => {
      // Serialize concurrent requests for this pair.
      const [lo, hi] = [user.id, receiverId].sort();
      await client.query('SELECT pg_advisory_xact_lock(hashtext($1))', [`${lo}:${hi}`]);

      const target = await client.query('SELECT id FROM users WHERE id = $1', [receiverId]);
      if (!target.rows[0]) throw notFound('No such user');

      const already = await client.query('SELECT 1 FROM contacts WHERE owner_id = $1 AND contact_id = $2', [
        user.id,
        receiverId,
      ]);
      if (already.rows[0]) throw new HttpError(409, 'already_contacts', 'You are already contacts');

      // They already asked us: sending a request back means "accept".
      const reverse = await client.query(
        `UPDATE contact_requests SET status = 'accepted', updated_at = now()
          WHERE sender_id = $2 AND receiver_id = $1 AND status = 'pending' RETURNING id`,
        [user.id, receiverId],
      );
      if (reverse.rows[0]) {
        await makeContacts(client, user.id, receiverId);
        return { id: reverse.rows[0].id, accepted: true };
      }

      const { rows } = await client.query(
        `INSERT INTO contact_requests (sender_id, receiver_id) VALUES ($1, $2)
         ON CONFLICT (sender_id, receiver_id) DO UPDATE
           SET status = 'pending',
               created_at = CASE WHEN contact_requests.status = 'pending' THEN contact_requests.created_at ELSE now() END,
               updated_at = now()
         RETURNING id`,
        [user.id, receiverId],
      );
      return { id: rows[0].id, accepted: false };
    });

    const request = await loadRequest(outcome.id);
    if (outcome.accepted) {
      await becameContacts(user.id, receiverId);
      hub.sendTo(receiverId, { type: 'contact_request_update', request });
    } else {
      hub.sendTo(receiverId, { type: 'contact_request', request });
    }
    return { status: outcome.accepted ? 200 : 201, body: request };
  });

  router.add('POST', '/api/contact-requests/:id/accept', async ({ params, user }) => {
    const id = v.uuid(params.id);
    const senderId = await withTransaction(pool, async (client) => {
      const { rows } = await client.query(
        `UPDATE contact_requests SET status = 'accepted', updated_at = now()
          WHERE id = $1 AND receiver_id = $2 AND status = 'pending'
          RETURNING sender_id`,
        [id, user.id],
      );
      if (!rows[0]) throw notFound('No pending request with that id addressed to you');
      const sender = rows[0].sender_id;
      await makeContacts(client, user.id, sender);
      // A crossing request in the other direction is settled too.
      await client.query(
        `UPDATE contact_requests SET status = 'accepted', updated_at = now()
          WHERE sender_id = $1 AND receiver_id = $2 AND status = 'pending'`,
        [user.id, sender],
      );
      return sender;
    });
    const request = await loadRequest(id);
    await becameContacts(user.id, senderId);
    hub.sendTo(senderId, { type: 'contact_request_update', request });
    return request;
  });

  router.add('POST', '/api/contact-requests/:id/reject', async ({ params, user }) => {
    const id = v.uuid(params.id);
    const { rows } = await pool.query(
      `UPDATE contact_requests SET status = 'rejected', updated_at = now()
        WHERE id = $1 AND receiver_id = $2 AND status = 'pending'
        RETURNING sender_id`,
      [id, user.id],
    );
    if (!rows[0]) throw notFound('No pending request with that id addressed to you');
    const request = await loadRequest(id);
    hub.sendTo(rows[0].sender_id, { type: 'contact_request_update', request });
    return request;
  });

  /** The sender withdraws a pending request. */
  router.add('DELETE', '/api/contact-requests/:id', async ({ params, user }) => {
    const id = v.uuid(params.id);
    const { rows } = await pool.query(
      `DELETE FROM contact_requests WHERE id = $1 AND sender_id = $2 AND status = 'pending'
       RETURNING receiver_id`,
      [id, user.id],
    );
    if (!rows[0]) throw notFound('No pending request with that id sent by you');
    hub.sendTo(rows[0].receiver_id, {
      type: 'contact_request_update',
      request: { id, sender_user_id: user.id, receiver_user_id: rows[0].receiver_id, status: 'cancelled' },
    });
  });

  // ---------------------------------------------------------------------------
  // Contacts
  // ---------------------------------------------------------------------------

  router.add('GET', '/api/contacts', async ({ user }) => {
    const { rows } = await pool.query(
      `SELECT c.contact_id, c.nickname, c.added_at, ${USER_COLUMNS}
         FROM contacts c JOIN users u ON u.id = c.contact_id
        WHERE c.owner_id = $1
        ORDER BY c.added_at`,
      [user.id],
    );
    const profs = await profiles(rows, new Set(rows.map((r) => r.id)));
    return rows.map((r, i) => ({
      contact_user_id: r.contact_id,
      nickname: r.nickname,
      added_at: r.added_at,
      contact_user: profs[i],
    }));
  });

  router.add('PATCH', '/api/contacts/:userId', async ({ params, body, user }) => {
    const contactId = v.uuid(params.userId, 'userId');
    v.requireObject(body);
    const nickname = v.optionalNickname(body.nickname);
    const { rowCount } = await pool.query('UPDATE contacts SET nickname = $3 WHERE owner_id = $1 AND contact_id = $2', [
      user.id,
      contactId,
      nickname,
    ]);
    if (!rowCount) throw notFound('Not a contact');
    return { contact_user_id: contactId, nickname };
  });

  /** Removing a contact removes the edge for both people. */
  router.add('DELETE', '/api/contacts/:userId', async ({ params, user }) => {
    const contactId = v.uuid(params.userId, 'userId');
    const removed = await withTransaction(pool, async (client) => {
      const { rowCount } = await client.query(
        `DELETE FROM contacts
          WHERE (owner_id = $1 AND contact_id = $2) OR (owner_id = $2 AND contact_id = $1)`,
        [user.id, contactId],
      );
      await client.query(
        `DELETE FROM contact_requests
          WHERE (sender_id = $1 AND receiver_id = $2) OR (sender_id = $2 AND receiver_id = $1)`,
        [user.id, contactId],
      );
      return rowCount;
    });
    if (!removed) throw notFound('Not a contact');
    await services.contactsChanged(user.id, contactId);
    hub.sendTo(contactId, { type: 'contact_removed', user_id: user.id });
  });

  // ---------------------------------------------------------------------------
  // Relay queue (ciphertext only, in Redis with a native TTL)
  // ---------------------------------------------------------------------------

  /**
   * The envelope must be a v2 wire envelope sent by the session's user:
   * {"v":2,"id":"…","s":"<sender id>","t":<ms>,"c":"<base64 NaCl box>"}.
   * The server cannot read `c`; it only checks the outer shape so that a
   * buggy client can't park plaintext or spoof the sender here.
   */
  function validateEnvelope(raw, senderId) {
    const text = v.string(raw, 'envelope', { min: 2, max: 128 * 1024 });
    let env;
    try {
      env = JSON.parse(text);
    } catch {
      throw bad('envelope must be JSON', 'invalid_envelope');
    }
    const keys = env && typeof env === 'object' && !Array.isArray(env) ? Object.keys(env).sort().join(',') : '';
    if (
      keys !== 'c,id,s,t,v' ||
      env.v !== 2 ||
      env.s !== senderId ||
      typeof env.id !== 'string' ||
      env.id.length < 1 ||
      env.id.length > 64 ||
      !Number.isSafeInteger(env.t) ||
      typeof env.c !== 'string' ||
      env.c.length < 64 ||
      !/^[A-Za-z0-9+/]+={0,2}$/.test(env.c)
    ) {
      throw bad('envelope is not a valid v2 ciphertext envelope from you', 'invalid_envelope');
    }
    return text;
  }

  router.add('POST', '/api/relay', async ({ body, user }) => {
    await limit('relay', user.id);
    v.requireObject(body);
    const recipientId = v.uuid(body.recipient_id, 'recipient_id');
    const envelope = validateEnvelope(body.envelope, user.id);
    if (!(await services.areContacts(user.id, recipientId))) {
      throw new HttpError(403, 'not_contacts', 'You can only message accepted contacts');
    }
    const msg = await store.relayEnqueue(user.id, recipientId, envelope);
    if (!msg) throw new HttpError(429, 'recipient_queue_full', 'The recipient has too many undelivered messages');
    const pushed =
      hub.sendTo(recipientId, {
        type: 'relay',
        message: { id: msg.id, sender_id: user.id, envelope, created_at: msg.created_at },
      }) > 0;
    return { status: 201, body: { id: msg.id, created_at: msg.created_at, expires_at: msg.expires_at, pushed } };
  });

  router.add('GET', '/api/relay', async ({ query, user }) => {
    const n = Math.min(Math.max(Number.parseInt(query.get('limit') ?? '100', 10) || 100, 1), 200);
    return store.relayFetch(user.id, n);
  });

  router.add('POST', '/api/relay/ack', async ({ body, user }) => {
    v.requireObject(body);
    const ids = body.ids;
    if (!Array.isArray(ids) || ids.length === 0 || ids.length > 200 || !ids.every(v.isUuid)) {
      throw bad('ids must be 1-200 UUIDs');
    }
    return { deleted: await store.relayAck(user.id, ids.map((id) => id.toLowerCase())) };
  });

  router.add('DELETE', '/api/relay/:id', async ({ params, user }) => {
    await store.relayAck(user.id, [v.uuid(params.id)]);
  });
}
