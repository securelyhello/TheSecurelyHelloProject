# Deploying the Securely Hello server

One Node.js container plus its own Redis, behind a TLS-terminating reverse
proxy. Postgres is Neon (remote). Written for Coolify + Traefik, but any Docker
host works.

## What runs

| Piece | Where | Holds |
|---|---|---|
| `app` (this folder's `Dockerfile`) | container, port 8787, non-root | nothing; stateless |
| `redis` (in `docker-compose.yml`) | container, named volume, not exposed | presence, rate limits, caches, the 24 h **ciphertext** relay queue |
| Postgres | Neon | accounts, password hashes, session-token hashes, public keys, contacts, hashed e-mail codes (`auth_tokens`, expire after 15/30 min) |

Run **one** `app` instance: WebSocket routing is in-process.

## Coolify

1. New resource → Docker Compose → this repository, base directory `/server`,
   compose file `docker-compose.yml`.
2. Attach the domain (e.g. `https://api.hello.thenn.in`) to service `app`,
   port `8787`. Do not publish host ports.
3. Environment variables:

   | Name | Required | Value |
   |---|---|---|
   | `DATABASE_URL` | yes | Neon **pooled** connection string (`...-pooler...neon.tech/neondb?sslmode=require`) |
   | `MIGRATION_DATABASE_URL` | no | Neon direct (non-pooled) string; migrations fall back to `DATABASE_URL` |
   | `TRUST_PROXY` | no | proxy hops that set `X-Forwarded-For`; default `1` (Traefik) |
   | `MIGRATE_ON_START` | no | default `1`: pending migrations are applied at boot under an advisory lock |
   | `LOG_LEVEL` | no | `info` (default), `debug`, `warn`, `error` |
   | `TURN_SECRET` | for TURN | coturn `static-auth-secret` (REST auth); mark it as a secret in Coolify. TURN is disabled when `TURN_SECRET` or `TURN_URLS` is empty |
   | `TURN_URLS` | for TURN | e.g. `turn:turn.thenn.in:3478?transport=udp,turn:turn.thenn.in:3478?transport=tcp` |
   | `TURN_TTL_SECONDS` | no | lifetime of the credentials `GET /api/turn` issues, default `3600`; the app refreshes 5 min before expiry (or at half the TTL if sooner) |
   | `EMAIL_PROVIDER` | to send e-mail | must be `resend` or `brevo` to send anything. The default `log` is a dry-run whatever else is set, and logs a warning in production |
   | `EMAIL_FROM` | for e-mail | sender on `thenn.in` itself, e.g. `Securely Hello <no-reply@thenn.in>` (strict DMARC: a subdomain sender fails alignment) |
   | `EMAIL_API_KEY` | for e-mail | provider API key; mark it as a secret in Coolify |
   | `EMAIL_DAILY_CAP` | no | global e-mails per 24 h (sliding), default `90`, minimum `2` (lower values are raised to 2 with a warning). Verification e-mails stop at 2/3 of it (60 by default, 26 at 40) so resets keep working |
   | `CODE_HMAC_KEY` | recommended | HMAC-SHA256 key for stored e-mail code hashes; generate with `openssl rand -hex 32` and mark it as a secret. Unset = random per process (warning in production): a restart then only invalidates live codes (30 min at most). Required for consistent codes across several instances |

   `REDIS_URL`, `PORT` and `HOST` are set by the compose file. If
   `EMAIL_PROVIDER` is `log`/unset, or `EMAIL_FROM` or `EMAIL_API_KEY` is
   missing, or the provider is unknown, the server runs e-mail in dry-run mode
   and says so at startup (a warning in production; a second warning if
   `EMAIL_API_KEY` is set while the provider is `log`).

   Per-sender limits on top of the daily cap: password-reset requests 3/h and
   5/day per e-mail address, 5/h and 20/day per IP; verification requests 3/h
   per account. While a code is live and under 60 s old, a repeat request
   gets the same 200 and no new mail.
4. Health check: `GET /healthz` returns 200 only when Postgres and Redis both
   answer (503 otherwise). The image and compose file already define it.
5. Deploy. Updating = redeploy; the container drains WebSockets on `SIGTERM`
   (clients reconnect with jittered back-off) and Redis keeps the relay queue
   in its volume (AOF).

## TURN (coturn)

Production runs coturn at `turn.thenn.in:3478` (UDP and TCP) with
`use-auth-secret` and `static-auth-secret` set to the same value as
`TURN_SECRET`. Signed-in clients call `GET /api/turn` (bearer, rate-limited
per account, `Cache-Control: no-store`) and get
`{urls, username: "<unix_expiry>:<userId>", credential, ttl}`, where
`credential` is base64 HMAC-SHA1 of `username` under `TURN_SECRET`. Nothing is
stored; coturn checks the HMAC and expiry itself. Open 3478/udp and 3478/tcp
plus coturn's relay port range on the TURN host.

Harden coturn so authenticated users can't use it to reach internal networks
(production already runs with this). In `turnserver.conf`:

```
use-auth-secret
static-auth-secret=<same value as TURN_SECRET>
realm=turn.thenn.in
no-cli
no-multicast-peers
# Never relay to private, loopback, link-local or other special ranges.
denied-peer-ip=0.0.0.0-0.255.255.255
denied-peer-ip=10.0.0.0-10.255.255.255
denied-peer-ip=100.64.0.0-100.127.255.255
denied-peer-ip=127.0.0.0-127.255.255.255
denied-peer-ip=169.254.0.0-169.254.255.255
denied-peer-ip=172.16.0.0-172.31.255.255
denied-peer-ip=192.0.0.0-192.0.0.255
denied-peer-ip=192.168.0.0-192.168.255.255
denied-peer-ip=198.18.0.0-198.19.255.255
denied-peer-ip=240.0.0.0-255.255.255.255
denied-peer-ip=::1
denied-peer-ip=fc00::-fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff
denied-peer-ip=fe80::-febf:ffff:ffff:ffff:ffff:ffff:ffff:ffff
# Quotas: cap allocations per user and in total, and per-session bandwidth.
user-quota=12
total-quota=1200
max-bps=1000000
```

Also deny the TURN host's own public address if other services listen on it.

## E-mail (Resend)

1. In Resend, add the domain `thenn.in` (the root domain, so `EMAIL_FROM` on
   `thenn.in` aligns under strict DMARC).
2. Add the DNS records Resend shows:
   - DKIM: `TXT` at `resend._domainkey.thenn.in`.
   - SPF: `TXT` `v=spf1 include:amazonses.com ~all` at `send.thenn.in` (the
     bounce/return-path subdomain), not at the root.
   - `MX` at `send.thenn.in` (the value Resend shows).

   Don't change the root `thenn.in` SPF record or `_dmarc`: DMARC aligns
   through the DKIM signature on `thenn.in`.
3. Wait until Resend shows the domain as verified, create an API key with
   sending access only, and set `EMAIL_PROVIDER=resend`, `EMAIL_FROM` and
   `EMAIL_API_KEY`.
4. Test: request a password reset in the app for your own account. Over the
   daily cap, reset requests still return 200 (a warning is logged) and
   verification requests return 503.

Brevo works the same way (`EMAIL_PROVIDER=brevo`) after authenticating
`thenn.in` in Brevo.

## Proxy requirements

- Everything the app calls lives under `/api/` (WebSocket: `/api/ws`), so a
  bot filter that exempts `/api/` lets the mobile client through.
- WebSocket upgrade must pass through; idle timeout should exceed 60 s (the
  server pings every 30 s, the client every 25 s).
- The app enforces its own per-account and per-IP limits in Redis; they sit
  well inside a proxy limit of 50 req/s per IP.

## Running migrations by hand

```
docker compose run --rm app node src/migrate.js
```

## Local development

`scripts/dev.sh` (repo root) starts Postgres and Redis in Docker, migrates and
runs the server on `:8787`. `npm test` in this folder runs the suite against
those containers (it uses its own `securelyhello_test` database and Redis
database 15).
