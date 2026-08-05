#!/usr/bin/env bash
# =============================================================================
# List services whose running container tag does not match .env IMAGE_* pin.
# Prints a comma-separated list (e.g. portal,api). Empty if all match.
#
# Usage:
#   ./scripts/mismatched-services.sh
#   DEPLOY_SERVICES=portal,api ./scripts/mismatched-services.sh
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

running_tag() {
  local svc="$1"
  local cid
  cid="$(docker compose ps -q "${svc}" 2>/dev/null || true)"
  if [[ -z "${cid}" ]]; then
    echo ""
    return
  fi
  docker inspect -f '{{index .Config.Image}}' "${cid}" 2>/dev/null | awk -F: '{print $NF}'
}

mismatched=()
for svc in "${SERVICE_LIST[@]}"; do
  svc="$(echo "${svc}" | xargs)"
  [[ -z "${svc}" ]] && continue
  var="$(service_image_var "${svc}")"
  [[ -z "${var}" ]] && continue
  expected="$(image_tag "${!var}")"
  actual="$(running_tag "${svc}")"
  if [[ -z "${actual}" || "${actual}" != "${expected}" ]]; then
    mismatched+=("${svc}")
  fi
done

(IFS=','; echo "${mismatched[*]}")
