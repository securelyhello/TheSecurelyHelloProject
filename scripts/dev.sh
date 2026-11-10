#!/usr/bin/env bash
# Local development backend: Postgres and Redis in Docker + migrations + the server.
#
#   scripts/dev.sh            start everything (server in the foreground)
#   scripts/dev.sh db         only start Postgres + Redis and migrate
#   scripts/dev.sh stop       stop the containers (data is kept)
#   scripts/dev.sh reset      delete the containers and their data
#
# Uses its own container (securelyhello-pg-dev) on host port 55432 so it never
# collides with another local Postgres. The server listens on :8787; point the
# app at it with API_BASE_URL in the project's .env (see .env.example).
#
# This script always targets the local container, even if server/.env points
# at Neon: the environment variable below takes precedence over server/.env.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTAINER="${SH_PG_CONTAINER:-securelyhello-pg-dev}"
PG_PORT="${SH_PG_PORT:-55432}"
PG_USER=sh
PG_PASSWORD=sh_dev_password
PG_DB=securelyhello
IMAGE=postgres:17-alpine
REDIS_CONTAINER="${SH_REDIS_CONTAINER:-securelyhello-redis-dev}"
REDIS_PORT="${SH_REDIS_PORT:-56379}"

export REDIS_URL="redis://127.0.0.1:${REDIS_PORT}/0"
export MIGRATE_ON_START=0
export DATABASE_URL="postgresql://${PG_USER}:${PG_PASSWORD}@127.0.0.1:${PG_PORT}/${PG_DB}"

start_redis() {
  if ! docker container inspect "$REDIS_CONTAINER" >/dev/null 2>&1; then
    echo "[dev] creating $REDIS_CONTAINER on 127.0.0.1:${REDIS_PORT}"
    docker run -d --name "$REDIS_CONTAINER" -p "127.0.0.1:${REDIS_PORT}:6379" redis:7.4-alpine \
      redis-server --maxmemory 128mb --maxmemory-policy noeviction >/dev/null
  elif [ "$(docker container inspect -f '{{.State.Running}}' "$REDIS_CONTAINER")" != "true" ]; then
    echo "[dev] starting $REDIS_CONTAINER"
    docker start "$REDIS_CONTAINER" >/dev/null
  fi
}

start_db() {
  start_redis
  if ! docker container inspect "$CONTAINER" >/dev/null 2>&1; then
    echo "[dev] creating $CONTAINER on 127.0.0.1:${PG_PORT}"
    docker run -d --name "$CONTAINER" \
      -e POSTGRES_USER="$PG_USER" -e POSTGRES_PASSWORD="$PG_PASSWORD" -e POSTGRES_DB="$PG_DB" \
      -p "127.0.0.1:${PG_PORT}:5432" "$IMAGE" >/dev/null
  elif [ "$(docker container inspect -f '{{.State.Running}}' "$CONTAINER")" != "true" ]; then
    echo "[dev] starting $CONTAINER"
    docker start "$CONTAINER" >/dev/null
  fi
  echo -n "[dev] waiting for Postgres"
  for _ in $(seq 1 60); do
    if docker exec "$CONTAINER" pg_isready -U "$PG_USER" -d "$PG_DB" >/dev/null 2>&1; then
      echo " ready"
      return
    fi
    echo -n "."
    sleep 1
  done
  echo
  echo "[dev] Postgres did not become ready" >&2
  exit 1
}

prepare_server() {
  cd "$ROOT/server"
  if [ ! -d node_modules ]; then
    echo "[dev] installing server dependencies"
    npm ci --no-audit --no-fund
  fi
  npm run --silent migrate
}

case "${1:-up}" in
  up)
    start_db
    prepare_server
    exec npm run --silent start
    ;;
  db)
    start_db
    prepare_server
    ;;
  stop)
    docker stop "$CONTAINER" "$REDIS_CONTAINER" >/dev/null && echo "[dev] stopped $CONTAINER $REDIS_CONTAINER"
    ;;
  reset)
    docker rm -f "$CONTAINER" "$REDIS_CONTAINER" >/dev/null && echo "[dev] removed $CONTAINER $REDIS_CONTAINER"
    ;;
  *)
    echo "usage: $0 [up|db|stop|reset]" >&2
    exit 2
    ;;
esac
