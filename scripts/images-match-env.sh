#!/usr/bin/env bash
# =============================================================================
# Exit 0 when running container image tags match .env IMAGE_* pins for the
# requested services. Exit 1 when any service is missing or on the wrong tag.
#
# Usage:
#   ./scripts/images-match-env.sh
#   DEPLOY_SERVICES=portal,api ./scripts/images-match-env.sh
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

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
    *) echo "" ;;
  esac
}

image_tag() {
  local image="$1"
  if [[ "${image}" == *:* ]]; then
    echo "${image##*:}"
  else
    echo "${image}"
  fi
}

mismatch=0
for svc in "${SERVICE_LIST[@]}"; do
  svc="$(echo "${svc}" | xargs)"
  [[ -z "${svc}" ]] && continue
  var="$(service_image_var "${svc}")"
  if [[ -z "${var}" ]]; then
    continue
  fi
  expected="${!var}"
  expected_tag="$(image_tag "${expected}")"
  id="$(docker compose ps -q "${svc}" 2>/dev/null || true)"
  if [[ -z "${id}" ]]; then
    echo "MISMATCH ${svc}: container not running (expected ${expected_tag})"
    mismatch=1
    continue
  fi
  running="$(docker inspect -f '{{.Config.Image}}' "${id}" 2>/dev/null || echo "")"
  running_tag="$(image_tag "${running}")"
  if [[ "${running_tag}" != "${expected_tag}" ]]; then
    echo "MISMATCH ${svc}: running=${running_tag} expected=${expected_tag}"
    mismatch=1
  else
    echo "OK ${svc}: ${running_tag}"
  fi
done

exit "${mismatch}"
