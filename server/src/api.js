// HTTP API. Everything lives under /api/ (the edge proxy only lets
// non-browser clients through on that prefix). All JSON. Every route needs a
// Bearer session token unless registered with {auth:false}. The acting user
// is always taken from the session, never from the request body.
import { emailCapReached } from './codes.js';
import { withTransaction } from './db.js';
import { emailHash } from './invites.js';
import { hasBlocked } from './safety.js';
import { burnPasswordCheck, hashPassword, hashToken, newSessionToken, verifyPassword } from './security.js';
import * as v from './validate.js';
import { HttpError, bad } from './validate.js';

const notFound = (what = 'Not found') => new HttpError(404, 'not_found', what);
const tooMany = () => new HttpError(429, 'rate_limited', 'Too many requests, slow down');

const USER_COLUMNS =
  'u.id, u.email, u.username, u.display_name, u.created_at, u.email_verified_at, u.discoverable';



/**
 * @param {import('./http.js').Router} router
 * @param {object} deps
 * @param {import('pg').Pool} deps.pool
 * @param {import('./realtime.js').RealtimeHub} deps.hub
 * @param {import('./hotstore.js').HotStore} deps.store
 * @param {import('./services.js').Services} deps.services
 * @param {import('./ratelimit.js').RateLimits} deps.limits
 */
export function registerRoutes(router, { pool, hub, store, services, limits, config, mailer, codes, log, notifier, twoFactor, antiSpam, blobs }) {
  const verificationRequired = config.emailVerification === 'required';
  // Serialization

  /** Public profile. Presence is only revealed to contacts (and yourself). */
  const profile = (row, presence = null) => ({
    user_id: row.id,
    username: row.username,
    display_name: row.display_name,
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
    return {
      ...profile(row, pres.get(row.id)),
      email: row.email,
      email_verified: row.email_verified_at != null,
      email_verification_required: verificationRequired,
      discoverable: row.discoverable,
      created_at: row.created_at,
    };
  }

  // E-mail codes (verification, password reset)

  const { canSend, issueCode, consumeCode } = codes;

  /** With EMAIL_VERIFICATION=required, unverified accounts can't reach anyone. */
  async function requireVerified(userId) {
    if (!verificationRequired) return;
    const { rows } = await pool.query('SELECT email_verified_at FROM users WHERE id = $1', [userId]);
    if (!rows[0]?.email_verified_at) {
      throw new HttpError(403, 'email_unverified', 'Verify your e-mail address first');
    }
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

  // Health

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

  // Auth

  /** A proof-of-work challenge for signing up or asking for a reset e-mail. */
  router.add(
    'GET',
    '/api/auth/challenge',
    async ({ query, ip }) => {
      await limit('publicIp', ip);
      const purpose = query.get('purpose');
      if (purpose !== 'signup' && purpose !== 'reset') throw bad("purpose must be 'signup' or 'reset'");
      return antiSpam.issueChallenge(purpose);
    },
    { auth: false },
  );

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
      antiSpam.checkSignupEmail(email);
      await antiSpam.requirePow('signup', body.pow);
      await limit('signupIp', ip);
      // Keys are registered per device afterwards (PUT /api/devices/current).
      const passwordHash = await hashPassword(password);

      try {
        const { row, token } = await withTransaction(pool, async (client) => {
          const { rows } = await client.query(
            `INSERT INTO users AS u (email, username, display_name, password_hash, email_hash)
             VALUES ($1, $2, $3, $4, $5)
             RETURNING ${USER_COLUMNS}`,
            [email, username, displayName, passwordHash, emailHash(email)],
          );
          return { row: rows[0], token: await createSession(client, rows[0].id) };
        });
        if (mailer.enabled) {
          await issueCode(row.id, row.email, 'verify').catch((err) =>
            log.warn('verification e-mail failed', { user: row.id, error: err.message }),
          );
        }
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
      // Per address and IP, so guessing from one place doesn't lock the owner
      // out from another; plus a cap on wrong passwords per address from
      // anywhere, which a correct password never adds to.
      await limit('authAccount', `${email.toLowerCase()}|${ip}`);
      if (await limits.exhausted('authFailures', email.toLowerCase())) throw tooMany();
      const failed = async () => {
        await limits.take('authFailures', email.toLowerCase());
        throw new HttpError(401, 'invalid_credentials', 'Wrong email or password');
      };

      const { rows } = await pool.query(
        `SELECT ${USER_COLUMNS}, u.password_hash, u.suspended_at FROM users u WHERE lower(u.email) = lower($1)`,
        [email],
      );
      const row = rows[0];
      if (!row) {
        await burnPasswordCheck(body.password);
        await failed();
      }
      if (!(await verifyPassword(body.password, row.password_hash))) await failed();
      if (row.suspended_at) throw new HttpError(403, 'suspended', 'This account is suspended');
      await twoFactor.require(row.id, body.otp);
      const token = await createSession(pool, row.id);
      return { token, user: await me(row) };
    },
    { auth: false },
  );

  // The client closes its own WebSocket; a revoked token cannot open another.
  router.add('POST', '/api/auth/signout', async ({ token, user }) => {
    const hash = hashToken(token);
    await pool.query('DELETE FROM sessions WHERE token_hash = $1', [hash]);
    await services.revokeCachedSessions(user.id, [hash]);
    hub.disconnectSessions(user.id, [hash]);
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
    await services.revokeCachedSessions(user.id, revoked);
    hub.disconnectSessions(user.id, revoked);
  });

  // ---- e-mail verification ----

  router.add(
    'GET',
    '/api/config',
    async () => ({
      email_verification: config.emailVerification,
      password_reset: mailer.enabled,
      push: notifier.enabled,
    }),
    { auth: false },
  );

  router.add('POST', '/api/auth/email/send-verification', async ({ user }) => {
    // Daily cap first (without spending it), so a 503 doesn't burn the
    // user's own budget; issueCode() takes the global slot.
    if (!(await canSend('verify'))) throw emailCapReached();
    await limit('emailSend', `verify:${user.id}`);
    const { rows } = await pool.query('SELECT email, email_verified_at FROM users WHERE id = $1', [user.id]);
    if (!rows[0]) throw notFound();
    if (rows[0].email_verified_at) throw new HttpError(409, 'already_verified', 'Your e-mail is already verified');
    if (!mailer.enabled) throw new HttpError(503, 'email_unavailable', 'E-mail is not configured on this server');
    await issueCode(user.id, rows[0].email, 'verify');
    return { status: 202, body: { sent: true } };
  });

  router.add('POST', '/api/auth/email/verify', async ({ body, user }) => {
    v.requireObject(body);
    if (!(await consumeCode(user.id, 'verify', body.code))) {
      throw new HttpError(400, 'invalid_code', 'That code is wrong or has expired');
    }
    const { rows } = await pool.query(
      `UPDATE users u SET email_verified_at = COALESCE(email_verified_at, now()), updated_at = now()
        WHERE u.id = $1 RETURNING ${USER_COLUMNS}`,
      [user.id],
    );
    return me(rows[0]);
  });

  // ---- password reset ----

  /**
   * Always answers 202, whether or not the address has an account, so the
   * endpoint can't be used to find out who is registered.
   */
  router.add(
    'POST',
    '/api/auth/password/forgot',
    async ({ body, ip }) => {
      await limit('authIp', ip);
      v.requireObject(body);
      const email = v.email(body.email);
      if (!mailer.enabled) throw new HttpError(503, 'email_unavailable', 'Password reset is not available on this server');
      await antiSpam.requirePow('reset', body.pow);
      await limit('emailSend', `reset:${email.toLowerCase()}`);
      const { rows } = await pool.query('SELECT id, email FROM users WHERE lower(email) = lower($1)', [email]);
      if (rows[0]) {
        // Not awaited: the answer must take as long whether or not the address exists.
        issueCode(rows[0].id, rows[0].email, 'reset').catch((err) =>
          log.warn('reset e-mail failed', { user: rows[0].id, error: err.message }),
        );
      }
      return { status: 202, body: { sent: true } };
    },
    { auth: false },
  );

  /**
   * Sets a new password with a code from the e-mail, signs out every other
   * session, and signs this client in. Proving access to the inbox also
   * verifies the address.
   */
  router.add(
    'POST',
    '/api/auth/password/reset',
    async ({ body, ip }) => {
      await limit('authIp', ip);
      v.requireObject(body);
      const email = v.email(body.email);
      const next = v.password(body.new_password, 'new_password');
      await limit('authAccount', email.toLowerCase());
      const found = await pool.query('SELECT id, suspended_at FROM users WHERE lower(email) = lower($1)', [email]);
      const userId = found.rows[0]?.id;
      if (!userId || !(await consumeCode(userId, 'reset', body.code, { keep: true }))) {
        throw new HttpError(400, 'invalid_code', 'That code is wrong or has expired');
      }
      // Only after the code, so this can't reveal which addresses are suspended.
      if (found.rows[0].suspended_at) throw new HttpError(403, 'suspended', 'This account is suspended');
      // The inbox alone isn't enough when two-step verification is on.
      await twoFactor.require(userId, body.otp);
      if (!(await consumeCode(userId, 'reset', body.code))) {
        throw new HttpError(400, 'invalid_code', 'That code is wrong or has expired');
      }
      const hash = await hashPassword(next);
      const { row, token, revoked } = await withTransaction(pool, async (client) => {
        const { rows } = await client.query(
          `UPDATE users u SET password_hash = $2, email_verified_at = COALESCE(email_verified_at, now()),
                  updated_at = now()
            WHERE u.id = $1 RETURNING ${USER_COLUMNS}`,
          [userId, hash],
        );
        const res = await client.query('DELETE FROM sessions WHERE user_id = $1 RETURNING token_hash', [userId]);
        return {
          row: rows[0],
          revoked: res.rows.map((r) => r.token_hash),
          token: await createSession(client, userId),
        };
      });
      await services.revokeCachedSessions(userId, revoked);
      hub.disconnectUser(userId, 4001, 'password reset');
      return { token, user: await me(row) };
    },
    { auth: false },
  );

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

  // Me

  router.add('GET', '/api/me', async ({ user }) => {
    const { rows } = await pool.query(`SELECT ${USER_COLUMNS} FROM users u WHERE u.id = $1`, [user.id]);
    if (!rows[0]) throw notFound();
    return me(rows[0]);
  });

  /**
   * Re-checks the password ([body].current_password) and, with two-step
   * verification on, [body].otp, for changes a stolen session must not make.
   */
  async function requireFreshCredentials(userId, body) {
    await limit('authAccount', `pw:${userId}`);
    if (typeof body.current_password !== 'string' || body.current_password.length > 256) {
      throw bad('current_password is required');
    }
    const { rows } = await pool.query('SELECT password_hash FROM users WHERE id = $1', [userId]);
    if (!rows[0] || !(await verifyPassword(body.current_password, rows[0].password_hash))) {
      throw new HttpError(403, 'invalid_credentials', 'Current password is wrong');
    }
    await twoFactor.require(userId, body.otp);
  }

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
      // Contacts find and recognise you by username, so a stolen session
      // alone can't change it: the password (and 2FA code) again.
      await requireFreshCredentials(user.id, body);
    }
    if (body.discoverable !== undefined) {
      if (typeof body.discoverable !== 'boolean') throw bad('discoverable must be true or false');
      args.push(body.discoverable);
      sets.push(`discoverable = $${args.length}`);
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

  router.add('DELETE', '/api/me', async ({ body, user }) => {
    // Irreversible, so a stolen session alone can't do it: the password (and
    // 2FA code) again, as for a username change.
    await requireFreshCredentials(user.id, body ?? {});
    // Blobs outside Postgres aren't removed by the cascade (audit run 1, U3-4).
    const { rows: files } = await pool.query(
      "SELECT id FROM attachments WHERE uploader_id = $1 AND storage <> 'postgres'",
      [user.id],
    );
    for (const f of files) {
      await blobs.delete(f.id).catch((err) => log.warn('blob delete failed', { id: f.id, error: err.message }));
    }
    const contacts = await services.contactIds(user.id);
    const devices = await services.deviceIds(user.id);
    // ON DELETE CASCADE removes sessions, requests and contacts.
    const sessions = await withTransaction(pool, async (client) => {
      const res = await client.query('SELECT token_hash FROM sessions WHERE user_id = $1', [user.id]);
      await client.query('DELETE FROM users WHERE id = $1', [user.id]);
      return res.rows.map((r) => r.token_hash);
    });
    await services.revokeCachedSessions(user.id, sessions);
    await services.contactsChanged(user.id, ...contacts);
    await services.devicesChanged(user.id);
    await store.relayPurgeUser(user.id, devices);
    await store.forgetPresence(user.id);
    for (const id of contacts) hub.sendTo(id, { type: 'contact_removed', user_id: user.id });
    hub.disconnectUser(user.id, 4003, 'account deleted');
  });

  // Directory

  router.add('GET', '/api/users/search', async ({ query, user }) => {
    const q = (query.get('q') ?? '').trim().toLowerCase().replace(/^@/, '');
    if (q.length < 1 || q.length > 30) throw bad('q must be 1-30 characters');
    const { rows } = await pool.query(
      `SELECT ${USER_COLUMNS} FROM users u
        WHERE u.username LIKE '%' || $1 || '%' ESCAPE '\\' AND u.id <> $2
          AND (u.discoverable OR u.username = $3)
          AND ($4::boolean = false OR u.email_verified_at IS NOT NULL)
          AND u.suspended_at IS NULL
          AND NOT EXISTS (SELECT 1 FROM blocks b
                           WHERE (b.blocker_id = u.id AND b.blocked_id = $2)
                              OR (b.blocker_id = $2 AND b.blocked_id = u.id))
        ORDER BY (u.username = $3) DESC, (u.username LIKE $1 || '%' ESCAPE '\\') DESC, u.username
        LIMIT 20`,
      [v.escapeLike(q), user.id, q, verificationRequired],
    );
    return profiles(rows, new Set(await services.contactIds(user.id)));
  });

  async function lookup(user, where, arg) {
    const { rows } = await pool.query(`SELECT ${USER_COLUMNS} FROM users u WHERE ${where}`, [arg]);
    if (!rows[0]) throw notFound('No such user');
    // Someone who blocked you can't be looked up.
    if (rows[0].id !== user.id && (await hasBlocked(pool, rows[0].id, user.id))) throw notFound('No such user');
    const visible = new Set(await services.contactIds(user.id));
    visible.add(user.id);
    return (await profiles(rows, visible))[0];
  }

  router.add('GET', '/api/users/by-username/:username', ({ params, user }) =>
    lookup(user, 'u.username = $1', v.username(params.username)),
  );

  router.add('GET', '/api/users/:id', ({ params, user }) => lookup(user, 'u.id = $1', v.uuid(params.id)));

  // Contact requests

  const requestSelect = `
    SELECT r.id, r.sender_id, r.receiver_id, r.status, r.created_at, r.updated_at,
           s.id AS s_id, s.username AS s_username, s.display_name AS s_display_name,
           s.created_at AS s_created_at,
           t.id AS t_id, t.username AS t_username, t.display_name AS t_display_name
      FROM contact_requests r
      JOIN users s ON s.id = r.sender_id
      JOIN users t ON t.id = r.receiver_id`;

  const pick = (row, prefix) => ({
    id: row[`${prefix}_id`],
    username: row[`${prefix}_username`],
    display_name: row[`${prefix}_display_name`],
  });

  const requestJson = (row) => ({
    id: row.id,
    sender_user_id: row.sender_id,
    receiver_user_id: row.receiver_id,
    status: row.status,
    created_at: row.created_at,
    updated_at: row.updated_at,
    sender: profile(pick(row, 's')),
    // How long the sender has had an account: brand-new accounts asking
    // to connect are the usual spam pattern, so the app points them out.
    sender_joined_at: row.s_created_at,
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
          AND NOT EXISTS (SELECT 1 FROM blocks b WHERE b.blocker_id = r.receiver_id AND b.blocked_id = r.sender_id
                            AND r.receiver_id = $1)
        ORDER BY r.created_at DESC
        LIMIT 500`,
      [user.id],
    );
    return rows.map(requestJson);
  });

  router.add('POST', '/api/contact-requests', async ({ body, user }) => {
    await limit('contactRequest', user.id);
    await requireVerified(user.id);
    const { isNew } = await antiSpam.checkCanRequest(user.id);
    if (isNew) await limit('contactRequestNew', user.id);
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
    if (await hasBlocked(pool, user.id, receiverId)) {
      throw new HttpError(409, 'blocked_by_you', 'You blocked this person. Unblock them first.');
    }
    // If they blocked us the request is stored as usual but never shown to
    // them or announced, so the block stays invisible.
    const silenced = await hasBlocked(pool, receiverId, user.id);

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
      const reverse = silenced ? { rows: [] } : await client.query(
        `UPDATE contact_requests SET status = 'accepted', updated_at = now()
          WHERE sender_id = $2 AND receiver_id = $1 AND status = 'pending' RETURNING id`,
        [user.id, receiverId],
      );
      if (reverse.rows[0]) {
        await makeContacts(client, user.id, receiverId);
        return { id: reverse.rows[0].id, accepted: true };
      }

      const recent = await client.query(
        `SELECT 1 FROM contact_requests WHERE sender_id = $1 AND receiver_id = $2
            AND status = 'rejected' AND updated_at > now() - interval '7 days'`,
        [user.id, receiverId],
      );
      if (recent.rows[0]) {
        throw new HttpError(429, 'request_cooldown', 'They declined recently. You can ask again in a week.');
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
    } else if (!silenced) {
      hub.sendTo(receiverId, { type: 'contact_request', request });
      notifier.wakeUser(receiverId, 'request').catch((err) => log.warn('push failed', { error: err.message }));
    }
    return { status: outcome.accepted ? 200 : 201, body: request };
  });

  router.add('POST', '/api/contact-requests/:id/accept', async ({ params, user }) => {
    const id = v.uuid(params.id);
    await requireVerified(user.id);
    const senderId = await withTransaction(pool, async (client) => {
      const { rows } = await client.query(
        `UPDATE contact_requests SET status = 'accepted', updated_at = now()
          WHERE id = $1 AND receiver_id = $2 AND status = 'pending'
          RETURNING sender_id`,
        [id, user.id],
      );
      if (!rows[0]) throw notFound('No pending request with that id addressed to you');
      const sender = rows[0].sender_id;
      const blocked = await client.query(
        'SELECT 1 FROM blocks WHERE (blocker_id = $1 AND blocked_id = $2) OR (blocker_id = $2 AND blocked_id = $1)',
        [user.id, sender],
      );
      if (blocked.rows[0]) throw notFound('No pending request with that id addressed to you');
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
    await antiSpam.evaluate(rows[0].sender_id);
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
    // They never saw it if they blocked us; announcing the cancel would tell.
    if (await hasBlocked(pool, rows[0].receiver_id, user.id)) return;
    hub.sendTo(rows[0].receiver_id, {
      type: 'contact_request_update',
      request: { id, sender_user_id: user.id, receiver_user_id: rows[0].receiver_id, status: 'cancelled' },
    });
  });

  // Contacts

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
}
