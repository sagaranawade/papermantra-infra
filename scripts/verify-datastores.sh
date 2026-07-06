#!/usr/bin/env bash
# =============================================================================
# Verify MongoDB + Redis connectivity from api and pdf containers.
#
# Usage:
#   ./scripts/verify-datastores.sh
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

if [[ ! -f .env ]]; then
  echo "ERROR: .env not found."
  exit 1
fi

# shellcheck disable=SC1091
source .env

failed=0

echo ">> MongoDB (host container)..."
if docker compose exec -T mongodb mongosh --quiet \
  -u "${MONGO_ROOT_USER}" -p "${MONGO_ROOT_PASSWORD}" \
  --authenticationDatabase admin \
  --eval "const d=db.adminCommand('listDatabases'); print('databases:', d.databases.map(x=>x.name).join(', '))"; then
  echo "   OK"
else
  echo "   FAIL"
  failed=1
fi

echo ">> Redis (host container)..."
if docker compose exec -T redis redis-cli -a "${REDIS_PASSWORD}" --no-auth-warning ping | grep -q PONG; then
  echo "   OK"
else
  echo "   FAIL"
  failed=1
fi

echo ">> API actuator..."
if docker compose exec -T api wget -qO- http://localhost:9092/actuator/health 2>/dev/null | grep -q '"status":"UP"'; then
  echo "   OK"
else
  echo "   FAIL"
  failed=1
fi

echo ">> PDF actuator..."
if docker compose exec -T pdf curl -fsS http://localhost:9092/pdfgenerator/actuator/health 2>/dev/null | grep -q '"status":"UP"'; then
  echo "   OK"
else
  echo "   FAIL"
  failed=1
fi

echo ">> Shared question images volume (/app/images in api + pdf)..."
api_count="$(docker compose exec -T api sh -c 'ls -1 /app/images 2>/dev/null | wc -l' | tr -d ' \r')"
pdf_count="$(docker compose exec -T pdf sh -c 'ls -1 /app/images 2>/dev/null | wc -l' | tr -d ' \r')"
echo "   api files: ${api_count}, pdf files: ${pdf_count} (same volume when counts match after upload)"
if docker compose exec -T api sh -c 'test -d /app/images && touch /app/images/.write-test && rm -f /app/images/.write-test'; then
  echo "   OK writable"
else
  echo "   FAIL not writable"
  failed=1
fi

if [[ "${failed}" -eq 1 ]]; then
  echo ">> One or more checks failed."
  exit 1
fi

echo ">> All datastore checks passed."
