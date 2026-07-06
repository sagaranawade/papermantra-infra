#!/usr/bin/env bash
# =============================================================================
# Pull latest images and restart the stack with health verification.
# Called locally on the VPS or by GitHub Actions over SSH.
#
# Usage:
#   ./scripts/deploy.sh
#   ./scripts/deploy.sh --rollback-on-failure
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

ROLLBACK_ON_FAILURE=0
if [[ "${1:-}" == "--rollback-on-failure" ]]; then
  ROLLBACK_ON_FAILURE=1
fi

if [[ ! -f .env ]]; then
  echo "ERROR: .env not found."
  exit 1
fi

LOCK_FILE=".deploy-lock"
if [[ -f "${LOCK_FILE}" ]]; then
  echo "ERROR: Another deployment is in progress (${LOCK_FILE} exists)."
  exit 1
fi

touch "${LOCK_FILE}"
trap 'rm -f "${LOCK_FILE}"' EXIT

HISTORY_FILE=".deploy-history"
TIMESTAMP="$(date -u +"%Y%m%dT%H%M%SZ")"

echo ">> Recording current image tags..."
{
  echo "# ${TIMESTAMP}"
  grep '^IMAGE_' .env || true
} >> "${HISTORY_FILE}"

echo ">> Pulling latest images..."
docker compose pull

echo ">> Starting / updating containers..."
docker compose up -d --remove-orphans

echo ">> Waiting for core health checks..."
failed=0
wait_for() {
  local name="$1"
  local url="$2"
  local attempts="${3:-30}"
  local delay="${4:-10}"

  for i in $(seq 1 "${attempts}"); do
    if docker compose exec -T "${name}" sh -c "wget -qO- '${url}' >/dev/null 2>&1 || curl -fsS '${url}' >/dev/null 2>&1"; then
      echo "   ${name} is healthy (attempt ${i})"
      return 0
    fi
    echo "   ${name} not ready yet (${i}/${attempts})..."
    sleep "${delay}"
  done
  echo "   ERROR: ${name} failed health check"
  failed=1
  return 1
}

wait_for api "http://localhost:9092/actuator/health" 30 10 || true
wait_for pdf "http://localhost:9092/pdfgenerator/actuator/health" 30 10 || true
wait_for portal "http://localhost:8080/healthz" 20 5 || true
wait_for website "http://localhost:3000/" 20 5 || true

if [[ "${failed}" -eq 1 ]]; then
  echo ">> Deployment health checks failed."
  if [[ "${ROLLBACK_ON_FAILURE}" -eq 1 ]]; then
    echo ">> Rolling back..."
    "${ROOT_DIR}/scripts/rollback.sh"
  fi
  exit 1
fi

echo ">> Reloading nginx..."
docker compose exec -T nginx nginx -s reload 2>/dev/null || docker compose restart nginx

echo ">> Pruning dangling images..."
docker image prune -f

echo ">> Deployment complete."
