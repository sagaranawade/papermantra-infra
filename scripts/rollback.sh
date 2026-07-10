#!/usr/bin/env bash
# =============================================================================
# Restore the previous IMAGE_* tags from .deploy-history and redeploy.
#
# Usage:
#   ./scripts/rollback.sh
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

HISTORY_FILE=".deploy-history"

if [[ ! -f "${HISTORY_FILE}" ]]; then
  echo "ERROR: No deployment history found (${HISTORY_FILE})."
  exit 1
fi

# Find the second-to-last IMAGE block (previous deployment)
mapfile -t blocks < <(awk '/^# / { if (block) print block; block="" } { block = block $0 ORS } END { if (block) print block }' "${HISTORY_FILE}")

if [[ "${#blocks[@]}" -lt 2 ]]; then
  echo "ERROR: Not enough history entries to roll back."
  exit 1
fi

PREVIOUS="${blocks[$(( ${#blocks[@]} - 2 ))]}"
echo ">> Rolling back to previous image tags:"
echo "${PREVIOUS}"

while IFS= read -r line; do
  [[ "${line}" =~ ^IMAGE_ ]] || continue
  key="${line%%=*}"
  val="${line#*=}"
  if grep -q "^${key}=" .env; then
    sed -i.bak "s|^${key}=.*|${key}=${val}|" .env
  else
    echo "${line}" >> .env
  fi
done <<< "${PREVIOUS}"

rm -f .env.bak

echo ">> Pulling rolled-back images..."
docker compose pull

echo ">> Restarting core services..."
docker compose up -d --remove-orphans mongodb redis nginx portal website

echo ">> Starting API and waiting for health..."
docker compose up -d api
api_ok=0
for i in $(seq 1 30); do
  if docker compose exec -T api sh -c "wget -qO- http://localhost:9092/actuator/health >/dev/null 2>&1 || curl -fsS http://localhost:9092/actuator/health >/dev/null 2>&1"; then
    echo "   api is healthy (attempt ${i})"
    api_ok=1
    break
  fi
  echo "   api not ready yet (${i}/30)..."
  sleep 10
done
if [[ "${api_ok}" -ne 1 ]]; then
  echo "ERROR: API did not become healthy during rollback."
  docker compose logs --tail 80 api 2>&1 || true
  exit 1
fi

echo ">> Starting PDF (depends on healthy API)..."
docker compose up -d pdf
for i in $(seq 1 20); do
  if docker compose exec -T pdf sh -c "curl -fsS http://localhost:9092/pdfgenerator/actuator/health >/dev/null 2>&1"; then
    echo "   pdf is healthy (attempt ${i})"
    break
  fi
  if [[ "${i}" -eq 20 ]]; then
    echo "WARN: PDF health check did not pass during rollback."
    docker compose logs --tail 80 pdf 2>&1 || true
  fi
  echo "   pdf not ready yet (${i}/20)..."
  sleep 10
done

echo ">> Rollback complete."
