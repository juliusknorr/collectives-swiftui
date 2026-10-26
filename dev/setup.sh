#!/bin/sh
set -eu

cd "$(dirname "$0")"
command -v python3 >/dev/null 2>&1 || { echo 'Python 3 is required.' >&2; exit 1; }
docker compose version >/dev/null
docker compose up -d --wait --wait-timeout 360
docker compose exec -T nextcloud sh /opt/collectives-dev/bootstrap.sh
NEXTCLOUD_URL="http://localhost:${NEXTCLOUD_PORT:-8080}" python3 seed.py
printf '\nCollectives is ready: http://localhost:%s/apps/collectives\n' "${NEXTCLOUD_PORT:-8080}"
