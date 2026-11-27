#!/usr/bin/env bash
# P1 (prod4) : smoke PostgreSQL 19 réel — cluster temporaire, localhost
# uniquement, zéro dépendance réseau. Image locale postgres:19-alpine en
# one-shot (la machine n'a que le client 19, pas d'initdb hôte — le
# cluster « temporaire en /tmp » de la spec est donc posé en container) ;
# détruit en fin de lot (trap).
set -euo pipefail

IMAGE="${PG_SMOKE_IMAGE:-postgres:19-alpine}"
PORT="${PG_SMOKE_PORT:-54329}"
DSN="postgresql+asyncpg://tapitask@127.0.0.1:${PORT}/tapitask_smoke"

# POSTGRES_HOST_AUTH_METHOD=trust : cluster temporaire local, le DSN
# asyncpg (sans mot de passe) passe tel quel.
CID="$(docker run -d \
  -e POSTGRES_USER=tapitask -e POSTGRES_DB=tapitask_smoke \
  -e POSTGRES_HOST_AUTH_METHOD=trust \
  -p "127.0.0.1:${PORT}:5432" "$IMAGE")"
cleanup() {
  docker rm -f "$CID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# prêt quand pg_isready passe (l'image met ~1-2 s à initialiser sa data dir)
for _ in $(seq 1 40); do
  if docker exec "$CID" pg_isready -U tapitask >/dev/null 2>&1; then break; fi
  sleep 0.5
done
docker exec "$CID" pg_isready -U tapitask

export TAPITASK_PG_DSN="$DSN"
export DATABASE_URL="$DSN"

cd "$(dirname "$0")/.."
server/.venv/bin/python -m pytest server/tests/test_smoke_postgres.py -q
