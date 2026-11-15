import http from 'node:http';

import { registerRoutes } from './api.js';
import { HotStore } from './hotstore.js';
import { Router, bearerToken, clientIp, readJsonBody, sendJson } from './http.js';
import { logger } from './log.js';
import { createMailer } from './mailer.js';
import { MIN_EMAIL_DAILY_CAP, RateLimits, emailLimits } from './ratelimit.js';
import { RealtimeHub } from './realtime.js';
import { resolveCodeKey } from './security.js';
import { Services } from './services.js';
import { HttpError } from './validate.js';

/** EMAIL_DAILY_CAP: unset/garbage → 90; below 2 → 2 with a warning (0 must not mean "default"). */
function emailDailyCap(raw, log) {
  const n = Number.parseInt(String(raw ?? '').trim(), 10);
  if (!Number.isFinite(n)) return 90;
  if (n < MIN_EMAIL_DAILY_CAP) {
    log?.warn(`EMAIL_DAILY_CAP below ${MIN_EMAIL_DAILY_CAP}, using ${MIN_EMAIL_DAILY_CAP}`, { value: n });
    return MIN_EMAIL_DAILY_CAP;
  }
  return n;
}

export function loadConfig(env = process.env, { log = logger } = {}) {
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
    redisPrefix: env.REDIS_PREFIX || 'sh:',
    sweepIntervalMs: int('SWEEP_INTERVAL_MS', 60 * 60_000),
    logRequests: env.LOG_REQUESTS !== '0',
    email: {
      provider: (env.EMAIL_PROVIDER || 'log').trim().toLowerCase(),
      from: (env.EMAIL_FROM || '').trim(),
      apiKey: (env.EMAIL_API_KEY || '').trim(),
      dailyCap: emailDailyCap(env.EMAIL_DAILY_CAP, log),
      production: env.NODE_ENV === 'production',
    },
    // HMAC key for e-mail code hashes. Unset = random per process (see security.js).
    codeHmacKey: (env.CODE_HMAC_KEY || '').trim(),
    // TURN REST credentials (coturn use-auth-secret). Unset = STUN only.
    turn: {
      secret: env.TURN_SECRET || '',
      urls: String(env.TURN_URLS ?? '')
        .split(',')
        .map((u) => u.trim())
        .filter(Boolean),
      ttl: int('TURN_TTL_SECONDS', 3600),
    },
  };
}

/**
 * Builds the HTTP + WebSocket server. Nothing listens until `listen()`.
 * @param {{pool: import('pg').Pool, redis: import('ioredis').Redis, config?: object,
 *          limitOverrides?: object, storeOptions?: object, log?: object,
 *          mailer?: {send: (msg: object) => Promise<{ok: boolean, dryRun: boolean}>}}} opts
 */
export function createApp({
  pool,
  redis,
  config = loadConfig(),
  limitOverrides = {},
  storeOptions = {},
  log = logger,
  mailer,
}) {
  const email = config.email ?? loadConfig({}).email;
  mailer ??= createMailer({ ...email, log });
  const store = new HotStore(redis, {
    prefix: config.redisPrefix,
    relayTtlSeconds: config.relayTtlHours * 3600,
    ...storeOptions,
  });
  const services = new Services({ pool, store });
  const limits = new RateLimits(store, { ...emailLimits(email.dailyCap), ...limitOverrides });
  const hub = new RealtimeHub({ services, store, limits, trustProxyHops: config.trustProxyHops, log });
  const router = new Router();

  // Fire-and-forget work started by a request (e.g. e-mail sends) so the
  // response time doesn't reveal whether an account exists. Tracked so that
  // close() and tests can wait for it.
  const pending = new Set();
  function background(fn) {
    const p = Promise.resolve()
      .then(fn)
      .catch((err) => log.error('background task failed', { error: err?.message }))
      .finally(() => pending.delete(p));
    pending.add(p);
  }
  async function drain() {
    while (pending.size) await Promise.all([...pending]);
  }

  const codeKey = resolveCodeKey(config.codeHmacKey, { production: email.production, log });

  registerRoutes(router, { pool, hub, store, services, limits, config, mailer, background, log, codeKey });

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

      const ctx = { req, params, query: url.searchParams, ip: clientIp(req, config.trustProxyHops) };
      if (route.auth) {
        const token = bearerToken(req);
        const user = token ? await services.authenticate(token) : null;
        if (!user) throw new HttpError(401, 'unauthorized', 'Sign in again');
        if (!(await limits.take('api', user.id))) throw new HttpError(429, 'rate_limited', 'Too many requests');
        ctx.user = user;
        ctx.token = token;
      }
      if (req.method !== 'GET' && req.method !== 'HEAD') ctx.body = await readJsonBody(req);

      const result = await route.handler(ctx);
      if (result && typeof result === 'object' && 'status' in result && 'body' in result) {
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
      } else if (err?.code === '22P02' || err?.code === '23514') {
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
    const tokens = await pool.query('DELETE FROM auth_tokens WHERE expires_at <= now()');
    return { sessions: sessions.rowCount, authTokens: tokens.rowCount };
  }
  let sweepTimer = null;

  return {
    server,
    hub,
    pool,
    store,
    services,
    limits,
    sweep,
    mailer,
    drain,
    listen(port = config.port, host = config.host) {
      sweepTimer = setInterval(() => {
        sweep()
          .then((n) => (n.sessions || n.authTokens) && log.info('sweep', n))
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
      server.closeIdleConnections?.();
      await closed;
      await drain();
    },
  };
}
