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

   `REDIS_URL`, `PORT` and `HOST` are set by the compose file.
4. Health check: `GET /healthz` returns 200 only when Postgres and Redis both
   answer (503 otherwise). The image and compose file already define it.
5. Deploy. Updating = redeploy; the container drains WebSockets on `SIGTERM`
   (clients reconnect with jittered back-off) and Redis keeps the relay queue
   in its volume (AOF).

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
