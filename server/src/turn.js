// Short-lived TURN credentials (the TURN REST scheme; coturn's
// use-auth-secret). The username is "<expiry unix time>:<random>", the
// password an HMAC-SHA1 of it with the secret shared with the TURN server,
// which checks both without asking us. Nothing long-lived ends up inside
// the app, and a leaked credential stops working after TURN_TTL_HOURS.
//
// TURN only ever relays DTLS-encrypted WebRTC traffic.
import { createHmac, randomBytes } from 'node:crypto';

export function turnCredentials({ secret, urls, ttlSeconds }, now = Date.now()) {
  const username = `${Math.floor(now / 1000) + ttlSeconds}:${randomBytes(6).toString('hex')}`;
  const credential = createHmac('sha1', secret).update(username).digest('base64');
  return { urls, username, credential, ttl: ttlSeconds };
}

export function registerTurnRoutes(router, { config }) {
  /** ICE servers for this account's calls and direct links. */
  router.add('GET', '/api/turn', async () => {
    if (!config.turnSecret || config.turnUrls.length === 0) return { urls: [] };
    return turnCredentials({ secret: config.turnSecret, urls: config.turnUrls, ttlSeconds: config.turnTtlSeconds });
  });
}
