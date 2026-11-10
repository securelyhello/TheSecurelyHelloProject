// A deliberately tiny JSON router on top of node:http.
import { HttpError, bad } from './validate.js';

export const MAX_BODY_BYTES = 256 * 1024;

export class Router {
  constructor() {
    this.routes = [];
  }

  /**
   * @param {string} method
   * @param {string} pattern  e.g. '/v1/users/:id'
   * @param {Function} handler async (ctx) => body | {status, body} | undefined (204)
   * @param {{auth?: boolean}} opts  auth defaults to true
   */
  add(method, pattern, handler, { auth = true } = {}) {
    const keys = [];
    const re = new RegExp(
      '^' +
        pattern.replace(/\/:([a-zA-Z_]+)/g, (_, k) => {
          keys.push(k);
          return '/([^/]+)';
        }) +
        '$',
    );
    this.routes.push({ method, re, keys, handler, auth, pattern });
  }

  match(method, pathname) {
    let pathMatched = false;
    for (const r of this.routes) {
      const m = r.re.exec(pathname);
      if (!m) continue;
      pathMatched = true;
      if (r.method !== method) continue;
      const params = {};
      r.keys.forEach((k, i) => {
        params[k] = decodeURIComponent(m[i + 1]);
      });
      return { route: r, params };
    }
    return pathMatched ? { methodNotAllowed: true } : null;
  }
}

export function readJsonBody(req) {
  return new Promise((resolve, reject) => {
    const declared = Number(req.headers['content-length'] ?? 0);
    if (declared > MAX_BODY_BYTES) {
      reject(new HttpError(413, 'payload_too_large'));
      req.resume();
      return;
    }
    const chunks = [];
    let size = 0;
    let failed = false;
    req.on('data', (chunk) => {
      if (failed) return;
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        failed = true;
        reject(new HttpError(413, 'payload_too_large'));
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      if (failed) return;
      if (size === 0) return resolve(undefined);
      const type = String(req.headers['content-type'] ?? '');
      if (!type.toLowerCase().startsWith('application/json')) {
        return reject(new HttpError(415, 'unsupported_media_type', 'Content-Type must be application/json'));
      }
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString('utf8')));
      } catch {
        reject(bad('Malformed JSON'));
      }
    });
    req.on('error', reject);
  });
}

export function sendJson(res, status, body) {
  const headers = {
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
    'Referrer-Policy': 'no-referrer',
  };
  if (body === undefined || status === 204) {
    res.writeHead(status === 200 ? 204 : status, headers);
    res.end();
    return;
  }
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    ...headers,
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(payload),
  });
  res.end(payload);
}

export function bearerToken(req) {
  const header = req.headers.authorization;
  if (typeof header !== 'string') return null;
  const m = /^Bearer ([A-Za-z0-9_-]{43})$/.exec(header.trim());
  return m ? m[1] : null;
}

/**
 * The client address for rate limiting.
 *
 * With [trustedHops] = 0 the TCP peer is used. Behind N reverse proxies
 * (Traefik under Coolify = 1) each proxy appends the address it saw to
 * X-Forwarded-For, so the real client is the N-th entry from the right.
 * Anything further left was supplied by the client and is ignored, which makes
 * the header unspoofable as long as only the proxy can reach this server.
 */
export function clientIp(req, trustedHops = 0) {
  if (trustedHops > 0) {
    const fwd = req.headers['x-forwarded-for'];
    const raw = Array.isArray(fwd) ? fwd.join(',') : fwd;
    if (typeof raw === 'string' && raw.length) {
      const hops = raw.split(',').map((s) => s.trim()).filter(Boolean);
      const ip = hops[Math.max(0, hops.length - trustedHops)];
      if (ip) return ip;
    }
  }
  return req.socket.remoteAddress ?? 'unknown';
}
