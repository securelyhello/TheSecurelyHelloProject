# Deploying the Securely Hello server

One Node.js container plus its own Redis, behind a TLS-terminating reverse
proxy. Postgres is Neon (remote). Written for Coolify + Traefik, but any Docker
host works.

## What runs

| Piece | Where | Holds |
|---|---|---|
| `app` (this folder's `Dockerfile`) | container, port 8787, non-root | nothing; stateless |
| `redis` (in `docker-compose.yml`) | container, named volume, not exposed | presence, rate limits, caches, the 24 h **ciphertext** relay queue |
| Postgres | Neon | accounts, password hashes, session-token hashes, public keys, contacts |

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
   | `SMTP_URL` | recommended | e.g. `smtps://user:pass@smtp.example.com:465`; sends verification and password-reset codes |
   | `MAIL_FROM` | with SMTP | sender address, e.g. `Securely Hello <no-reply@example.com>` |
   | `EMAIL_VERIFICATION` | no | `required` (default with SMTP) or `optional` |
   | `FCM_SERVICE_ACCOUNT` | no | Firebase service-account JSON (inline or base64) for push wake-ups |
   | `ATTACHMENT_MAX_MB` / `ATTACHMENT_TTL_DAYS` / `ATTACHMENT_QUOTA_MB` | no | `16` / `30` / `512` |

   `REDIS_URL`, `PORT` and `HOST` are set by the compose file.
4. Health check: `GET /healthz` returns 200 only when Postgres and Redis both
   answer (503 otherwise). The image and compose file already define it.
5. Deploy. Updating = redeploy; the container drains WebSockets on `SIGTERM`
   (clients reconnect with jittered back-off) and Redis keeps the relay queue
   in its volume (AOF).

## E-mail

Without `SMTP_URL`, e-mail verification is optional and password reset is
unavailable (the app says so). In production (`NODE_ENV=production`, as in
the image) codes are never written to logs. Any SMTP provider works; codes
are 6 digits, valid 15 (reset) or 30 (verify) minutes, stored hashed, and
allow five guesses.

## Push wake-ups (optional)

1. Create a Firebase project and add an Android app (and an iOS app, with an
   APNs key uploaded under Cloud Messaging) with the app's bundle ids.
2. Server: Project settings → Service accounts → generate a key; put the
   JSON (or its base64) in `FCM_SERVICE_ACCOUNT`.
3. App: put the project id, sender id, API key and app ids in the app's
   `.env` (`FIREBASE_*`, see `.env.example`).

A push says only "You have a new message" or "You have a new contact
request". It is sent only to devices without a live socket, and at most
once per 30 s per device. The app then fetches and decrypts the queue
itself.

## Storage

Attachments are ciphertext blobs in Postgres (`attachments`, swept after
`ATTACHMENT_TTL_DAYS`). Size Neon storage accordingly, or lower the limits.
Request bodies for uploads go up to `ATTACHMENT_MAX_MB`, so the proxy must
allow bodies that large on `/api/attachments`.

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
