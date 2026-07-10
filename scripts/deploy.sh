#!/usr/bin/env bash
# =============================================================================
# Pull images and restart services with health verification.
#
# Usage:
#   ./scripts/deploy.sh
#   ./scripts/deploy.sh --rollback-on-failure
#   DEPLOY_SERVICES=pdf ./scripts/deploy.sh
#   DEPLOY_SERVICES=portal,api,pdf,website ./scripts/deploy.sh   # default: all app services
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

DEPLOY_SERVICES="${DEPLOY_SERVICES:-portal,website,api,pdf}"
IFS=',' read -r -a SERVICE_LIST <<< "${DEPLOY_SERVICES}"

set -a
# shellcheck disable=SC1091
source .env
set +a

service_image_var() {
  case "$1" in
    portal) echo "IMAGE_PAPERMANTRA" ;;
    website) echo "IMAGE_ROBOFUME" ;;
    api) echo "IMAGE_SERVICES" ;;
    pdf) echo "IMAGE_PDF" ;;
    *)
      echo "ERROR: unknown service '$1'" >&2
      exit 1
      ;;
  esac
}

wait_for_image() {
  local image="$1"
  local attempts="${2:-36}"
  local delay="${3:-10}"
  echo "   waiting for ${image}..."
  for i in $(seq 1 "${attempts}"); do
    if docker manifest inspect "${image}" >/dev/null 2>&1; then
      echo "   ${image} is available (attempt ${i})"
      return 0
    fi
    if [[ "${i}" -eq "${attempts}" ]]; then
      echo "   ERROR: ${image} not found in registry after $((attempts * delay))s"
      return 1
    fi
    sleep "${delay}"
  done
}

echo ">> Deploying services: ${DEPLOY_SERVICES}"
echo ">> Waiting for image(s) in registry..."
for svc in "${SERVICE_LIST[@]}"; do
  var="$(service_image_var "${svc}")"
  wait_for_image "${!var}"
done

echo ">> Pulling images..."
# shellcheck disable=SC2086
docker compose pull ${SERVICE_LIST[*]}

echo ">> Migrating legacy image volumes (one-time safe merge)..."
"${ROOT_DIR}/scripts/migrate-image-volumes.sh"

if [[ ",${DEPLOY_SERVICES}," == *",api,"* ]]; then
  echo ">> Ensuring API volume permissions (uid=100)..."
  "${ROOT_DIR}/scripts/fix-api-volume-permissions.sh"
fi

echo ">> Starting / updating containers..."
# shellcheck disable=SC2086
docker compose up -d --remove-orphans ${SERVICE_LIST[*]}

echo ">> Waiting for core health checks..."
failed=0
wait_for() {
  local name="$1"
  local url="$2"
  local attempts="${3:-30}"
  local delay="${4:-10}"
  local container_id=""
  local last_log_dump=0

  for i in $(seq 1 "${attempts}"); do
    container_id="$(docker compose ps -q "${name}" 2>/dev/null || true)"
    if [[ -n "${container_id}" ]]; then
      local state=""
      state="$(docker inspect -f '{{.State.Status}}' "${container_id}" 2>/dev/null || echo unknown)"
      if [[ "${state}" == "restarting" || "${state}" == "exited" ]]; then
        if [[ "${i}" -ge "${last_log_dump}" && $((i - last_log_dump)) -ge 3 ]]; then
          echo "   ${name} is ${state} — recent logs:"
          docker compose logs --tail 60 "${name}" 2>&1 || true
          last_log_dump="${i}"
        fi
      fi
    fi

    if docker compose exec -T "${name}" sh -c "wget -qO- '${url}' >/dev/null 2>&1 || curl -fsS '${url}' >/dev/null 2>&1"; then
      echo "   ${name} is healthy (attempt ${i})"
      return 0
    fi
    echo "   ${name} not ready yet (${i}/${attempts})..."
    sleep "${delay}"
  done

  echo "   ERROR: ${name} failed health check"
  echo "   Last logs for ${name}:"
  docker compose logs --tail 80 "${name}" 2>&1 || true
  failed=1
  return 1
}

for svc in "${SERVICE_LIST[@]}"; do
  case "${svc}" in
    api) wait_for api "http://localhost:9092/actuator/health" 30 10 || true ;;
    pdf) wait_for pdf "http://localhost:9092/pdfgenerator/actuator/health" 30 10 || true ;;
    portal) wait_for portal "http://localhost:8080/healthz" 20 5 || true ;;
    website) wait_for website "http://127.0.0.1:3000/" 20 5 || true ;;
  esac
done

# PDF depends on a healthy API. API-only deploys must still (re)start PDF or it can
# stay down after a failed rollback when the API was unhealthy.
if [[ ",${DEPLOY_SERVICES}," == *",api,"* ]] && [[ ",${DEPLOY_SERVICES}," != *",pdf,"* ]]; then
  echo ">> Ensuring PDF service is running (depends on API)..."
  docker compose up -d pdf
  wait_for pdf "http://localhost:9092/pdfgenerator/actuator/health" 20 10 || true
fi

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

if [[ "${DEPLOY_SERVICES}" == "portal,website,api,pdf" ]]; then
  echo ">> Verifying MongoDB, Redis, and shared images..."
  "${ROOT_DIR}/scripts/verify-datastores.sh"
fi

echo ">> Deployment complete."
