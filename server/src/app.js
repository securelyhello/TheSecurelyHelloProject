import { randomUUID } from 'node:crypto';
import http from 'node:http';

import { registerRoutes } from './api.js';
import { registerAttachmentRoutes } from './attachments.js';
import { createCodes } from './codes.js';
import { createBlobStore } from './blobstore.js';
import { registerDeviceRoutes } from './devices.js';
import { registerSafetyRoutes } from './safety.js';
import { registerInviteRoutes } from './invites.js';
import { registerGroupRoutes } from './groups.js';
import { createAntiSpam } from './spam.js';
import { createTwoFactor, registerTwoFactorRoutes } from './twofactor.js';
import { HotStore } from './hotstore.js';
import { Router, bearerToken, clientIp, containsNul, readJsonBody, readRawBody, sendBytes, sendJson } from './http.js';
import { logger } from './log.js';
import { createMailer } from './mail.js';
import { createNotifier, senderFromEnv } from './push.js';
import { RateLimits } from './ratelimit.js';
import { RealtimeHub } from './realtime.js';
import { Bus } from './bus.js';
import { Metrics, checkMetricsToken } from './metrics.js';
import { registerTurnRoutes } from './turn.js';
import { Services } from './services.js';
import { HttpError, bad } from './validate.js';

export function loadConfig(env = process.env) {
  const int = (name, def, { allowZero = false } = {}) => {
    const n = Number.parseInt(env[name] ?? '', 10);
    return Number.isFinite(n) && (n > 0 || (allowZero && n === 0)) ? n : def;
  };
  // TRUST_PROXY = number of reverse-proxy hops in front of us (0 = none).
  // "true"/"1" both mean one hop.
  const rawTrust = String(env.TRUST_PROXY ?? '0').toLowerCase();
  const trustProxyHops = rawTrust === 'true' ? 1 : int('TRUST_PROXY', 0, { allowZero: true });
  return {
    host: env.HOST || '0.0.0.0',
    port: int('PORT', 8787),
    trustProxyHops,
    sessionTtlDays: int('SESSION_TTL_DAYS', 90),
    relayTtlHours: int('RELAY_TTL_HOURS', 24),
    // Undelivered relay data allowed per recipient device and per sender.
    relayDeviceMb: int('RELAY_DEVICE_MAX_MB', 16),
    relaySenderMb: int('RELAY_SENDER_MAX_MB', 32),
    redisPrefix: env.REDIS_PREFIX || 'sh:',
    sweepIntervalMs: int('SWEEP_INTERVAL_MS', 60 * 60_000),
    logRequests: env.LOG_REQUESTS !== '0',
    // 'required': unverified accounts can't send or accept contact requests
    // and are hidden from search. Defaults to required when real e-mail
    // (SMTP) is configured, optional otherwise.
    emailVerification: (env.EMAIL_VERIFICATION || '').toLowerCase(),
    // Operator token for /api/admin/* (reports, suspensions); at least 32 chars.
    adminToken: env.ADMIN_TOKEN || '',
    // Encrypts two-step (TOTP) secrets at rest. Any long random string;
    // changing it makes existing secrets unreadable.
    totpKey: env.TOTP_ENCRYPTION_KEY || '',
    // Proof-of-work difficulty for signup and reset e-mails (leading zero
    // bits of SHA-256; 0 turns it off). 18 takes about a second on a phone.
    powBits: int('POW_BITS', 18, { allowZero: true }),
    blockDisposableEmail: env.BLOCK_DISPOSABLE_EMAIL !== '0',
    // Invite links: the token is appended. Point it at the website's /i/
    // page (see web/), which opens the app or offers to install it.
    inviteBaseUrl: env.INVITE_BASE_URL || 'securelyhello://invite/',
    attachmentMaxBytes: int('ATTACHMENT_MAX_MB', 16) * 1024 * 1024,
    attachmentTtlDays: int('ATTACHMENT_TTL_DAYS', 30),
    attachmentQuotaBytes: int('ATTACHMENT_QUOTA_MB', 512) * 1024 * 1024,
    // New accounts per client IP a day (raise it behind carrier-grade NAT,
    // where many people share an address).
    signupsPerIp: int('SIGNUPS_PER_IP_PER_DAY', 0),
    // Prometheus scrape token for GET /metrics; unset turns the route off.
    metricsToken: env.METRICS_TOKEN || '',
    // TURN relay for calls and direct links (see turn.js and DEPLOY.md).
    turnUrls: (env.TURN_URLS || '').split(',').map((u) => u.trim()).filter(Boolean),
    turnSecret: env.TURN_SECRET || '',
    turnTtlSeconds: int('TURN_TTL_HOURS', 12) * 3600,
  };
}

/**
 * Builds the HTTP + WebSocket server. Nothing listens until `listen()`.
 * @param {{pool: import('pg').Pool, redis: import('ioredis').Redis, config?: object,
 *          limitOverrides?: object, storeOptions?: object, log?: object}} opts
 */
export function createApp({
  pool,
  redis,
  config = loadConfig(),
  limitOverrides = {},
  storeOptions = {},
  log = logger,
  mailer = createMailer(),
  pushSender = senderFromEnv(process.env, log),
  blobs = createBlobStore(process.env, pool),
}) {
  config = { ...config };
  if (!mailer.enabled) {
    if (config.emailVerification === 'required') {
      log.warn('EMAIL_VERIFICATION=required ignored: e-mail is disabled (set SMTP_URL)');
    }
    config.emailVerification = 'optional';
  } else if (config.emailVerification !== 'required' && config.emailVerification !== 'optional') {
    config.emailVerification = mailer.transport === 'smtp' ? 'required' : 'optional';
  }
  const store = new HotStore(redis, {
    prefix: config.redisPrefix,
    relayTtlSeconds: config.relayTtlHours * 3600,
    relayDeviceBytes: config.relayDeviceMb * 1024 * 1024,
    relaySenderBytes: config.relaySenderMb * 1024 * 1024,
    ...storeOptions,
  });
  const services = new Services({ pool, store });
  const limits = new RateLimits(store, {
    ...(config.signupsPerIp ? { signupIp: { capacity: config.signupsPerIp, perMs: 24 * 60 * 60_000 } } : {}),
    ...limitOverrides,
  });
  const instanceId = randomUUID();
  const bus = new Bus({ redis, instanceId, prefix: config.redisPrefix, log });
  const metrics = new Metrics();
  const hub = new RealtimeHub({ services, store, limits, trustProxyHops: config.trustProxyHops, log, bus, instanceId });
  const notifier = createNotifier({ pool, store, hub, sender: pushSender, log });
  const router = new Router();
  const twoFactor = createTwoFactor({ pool, config, limits });
  const antiSpam = createAntiSpam({ pool, store, config, log });
  if (!config.totpKey) log.warn('TOTP_ENCRYPTION_KEY is not set: two-step secrets are stored unencrypted');
  registerRoutes(router, { pool, hub, store, services, limits, config, mailer, log, notifier, twoFactor, antiSpam, blobs });
  registerTwoFactorRoutes(router, { pool, twoFactor, limits });
  registerDeviceRoutes(router, {
    metrics,
    pool,
    hub,
    store,
    services,
    limits,
    log,
    notifier,
    mailer,
    codes: createCodes({ pool, mailer }),
    twoFactor,
  });
  registerAttachmentRoutes(router, { pool, services, limits, config, blobs });
  registerSafetyRoutes(router, { pool, hub, services, limits, config, antiSpam });
  registerInviteRoutes(router, { pool, hub, services, limits, config, antiSpam });
  registerGroupRoutes(router, { pool, services, limits });
  registerTurnRoutes(router, { config });
  router.add(
    'GET',
    '/metrics',
    async ({ req }) => {
      checkMetricsToken(config.metricsToken, req.headers.authorization);
      const queued = await store.redis.dbsize().catch(() => -1);
      return {
        status: 200,
        text: metrics.render({
          sh_ws_connections: ['Open WebSockets on this instance.', hub.connectionCount],
          sh_redis_keys: ['Keys in the Redis database (all instances).', queued],
          sh_db_pool_waiting: ['Queries waiting for a Postgres connection.', pool.waitingCount ?? 0],
        }),
      };
    },
    { auth: false },
  );

  const server = http.createServer(async (req, res) => {
    const started = Date.now();
    let status = 500;
    let pattern = 'unmatched';
    try {
      const url = new URL(req.url, 'http://localhost');
      const match = router.match(req.method, url.pathname);
      if (!match) throw new HttpError(404, 'not_found');
      if (match.methodNotAllowed) throw new HttpError(405, 'method_not_allowed');
      const { route, params } = match;
      pattern = route.pattern;

      // Postgres text can't hold NUL; refuse it here instead of failing deep in a query.
      if ([...url.searchParams.values(), ...Object.values(params)].some((x) => x.includes('\0'))) {
        throw bad('Input contains a NUL character');
      }
      const ctx = { req, params, query: url.searchParams, ip: clientIp(req, config.trustProxyHops) };
      if (route.auth) {
        const token = bearerToken(req);
        const user = await services.authenticate(token);
        if (!user) throw new HttpError(401, 'unauthorized', 'Sign in again');
        if (!(await limits.take('api', user.id))) throw new HttpError(429, 'rate_limited', 'Too many requests');
        ctx.user = user;
        ctx.token = token;
      }
      if (route.rawBody) ctx.body = await readRawBody(req, route.rawBody);
      else if (req.method !== 'GET' && req.method !== 'HEAD') {
        ctx.body = await readJsonBody(req);
        if (containsNul(ctx.body)) throw bad('Input contains a NUL character');
      }

      const result = await route.handler(ctx);
      if (Buffer.isBuffer(result)) {
        status = 200;
        sendBytes(res, 200, result);
      } else if (result && typeof result === 'object' && 'text' in result) {
        status = result.status;
        res.writeHead(status, { 'Content-Type': 'text/plain; version=0.0.4', 'Cache-Control': 'no-store' });
        res.end(result.text);
      } else if (result && typeof result === 'object' && 'status' in result && 'body' in result) {
        status = result.status;
        sendJson(res, result.status, result.body);
      } else {
        status = result === undefined ? 204 : 200;
        sendJson(res, status, result);
      }
    } catch (err) {
      if (err instanceof HttpError) {
        status = err.status;
        sendJson(res, err.status, { error: err.code, message: err.message });
      } else if (err?.code === '22P02' || err?.code === '23514' || err?.code === '22021') {
        // invalid_text_representation / check_violation: bad input that slipped past validation
        status = 400;
        sendJson(res, 400, { error: 'invalid_input', message: 'Invalid input' });
      } else {
        // Redis refusing writes (noeviction + full) or being down, or Postgres
        // being unreachable: the client should retry later.
        const unavailable =
          /OOM|MaxRetriesPerRequest|Connection is closed|ECONNREFUSED|ETIMEDOUT|timeout/i.test(String(err?.message));
        status = unavailable ? 503 : 500;
        log.error('http error', { method: req.method, route: pattern, error: err?.message });
        if (!res.headersSent) {
          sendJson(res, status, {
            error: unavailable ? 'unavailable' : 'internal',
            message: unavailable ? 'Service temporarily unavailable' : 'Internal server error',
          });
        }
      }
    } finally {
      metrics.observeRequest(req.method, pattern, status, Date.now() - started);
      // Route pattern only: never the raw path or query (ids, search terms).
      if (config.logRequests && pattern !== '/healthz') {
        log.info('http', { method: req.method, route: pattern, status, ms: Date.now() - started });
      }
    }
  });
  server.headersTimeout = 20_000;
  server.requestTimeout = 30_000;
  server.keepAliveTimeout = 65_000;
  server.on('upgrade', (req, socket, head) => {
    hub.handleUpgrade(req, socket, head);
  });

  /** Postgres housekeeping. Redis data expires on its own. */
  async function sweep() {
    const sessions = await pool.query('DELETE FROM sessions WHERE expires_at <= now()');
    const codes = await pool.query('DELETE FROM email_codes WHERE expires_at <= now()');
    // Reports (with any messages the reporter shared) are kept for a year.
    await pool.query("DELETE FROM reports WHERE created_at < now() - interval '365 days'");
    const attachments = await pool.query('DELETE FROM attachments WHERE expires_at <= now() RETURNING id, storage');
    for (const row of attachments.rows) {
      if (row.storage !== 'postgres') {
        await blobs.delete(row.id).catch((err) => log.warn('blob delete failed', { id: row.id, error: err.message }));
      }
    }
    return { sessions: sessions.rowCount, codes: codes.rowCount, attachments: attachments.rowCount };
  }
  let sweepTimer = null;

  return {
    server,
    config,
    mailer,
    notifier,
    hub,
    pool,
    store,
    services,
    limits,
    sweep,
    instanceId,
    async listen(port = config.port, host = config.host) {
      await bus.start((msg) => hub.onBusMessage(msg));
      sweepTimer = setInterval(async () => {
        // Every instance has the timer; one of them sweeps each round.
        if (!(await store.tryLock('sweep', config.sweepIntervalMs / 2).catch(() => false))) return;
        sweep()
          .then((n) => (n.sessions || n.codes || n.attachments) && log.info('sweep', n))
          .catch((err) => log.warn('sweep failed', { error: err.message }));
      }, config.sweepIntervalMs);
      sweepTimer.unref();
      return new Promise((resolve) => server.listen(port, host, () => resolve(server.address())));
    },
    /** Stops accepting, drains WebSockets, closes the listener. Pool/Redis are the caller's. */
    async close() {
      clearInterval(sweepTimer);
      const closed = new Promise((resolve) => server.close(() => resolve()));
      await hub.close();
      await bus.close();
      server.closeIdleConnections?.();
      await closed;
    },
  };
}
