#!/usr/bin/env bash
# =============================================================================
# On infra push (no pin_tag), deploy only services whose IMAGE_* line changed
# in the latest commit. Avoids recreating unrelated containers (e.g. api when
# only portal tag was bumped in .env).
#
# Usage:
#   ./scripts/resolve-deploy-services.sh
#   DEPLOY_SERVICES=$(./scripts/resolve-deploy-services.sh)
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

service_for_image_var() {
  case "$1" in
    IMAGE_PAPERMANTRA) echo "portal" ;;
    IMAGE_ROBOFUME) echo "website" ;;
    IMAGE_SERVICES) echo "api" ;;
    IMAGE_PDF) echo "pdf" ;;
    *) echo "" ;;
  esac
}

default_services() {
  echo "portal,website,api,pdf"
}

if ! git rev-parse HEAD~1 >/dev/null 2>&1; then
  default_services
  exit 0
fi

mapfile -t changed_vars < <(
  git diff --unified=0 HEAD~1 HEAD -- .env 2>/dev/null \
    | grep -E '^[+-]IMAGE_' \
    | sed -E 's/^[+-]//' \
    | cut -d= -f1 \
    | sort -u \
    || true
)

if [[ ${#changed_vars[@]} -eq 0 ]]; then
  default_services
  exit 0
fi

services=()
for var in "${changed_vars[@]}"; do
  svc="$(service_for_image_var "${var}")"
  if [[ -n "${svc}" ]]; then
    services+=("${svc}")
  fi
done

if [[ ${#services[@]} -eq 0 ]]; then
  default_services
  exit 0
fi

(IFS=','; echo "${services[*]}")
