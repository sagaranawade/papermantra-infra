#!/usr/bin/env bash
# =============================================================================
# Write deploy-meta.json from the currently running containers + .env pins.
# Served publicly at https://papermantra.com/deploy-meta.json for CI smoke tests.
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

META_DIR="${ROOT_DIR}/deploy-meta"
META_FILE="${META_DIR}/deploy-meta.json"
mkdir -p "${META_DIR}"

set -a
# shellcheck disable=SC1091
source .env
set +a

image_tag() {
  local image="$1"
  if [[ "${image}" == *:* ]]; then
    echo "${image##*:}"
  else
    echo "unknown"
  fi
}

running_image() {
  local service="$1"
  local id
  id="$(docker compose ps -q "${service}" 2>/dev/null || true)"
  if [[ -z "${id}" ]]; then
    echo ""
    return 0
  fi
  docker inspect -f '{{.Config.Image}}' "${id}" 2>/dev/null || echo ""
}

portal_img="$(running_image portal)"
website_img="$(running_image website)"
api_img="$(running_image api)"
pdf_img="$(running_image pdf)"

cat > "${META_FILE}.tmp" <<EOF
{
  "updatedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "gitHead": "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)",
  "expected": {
    "portal": "$(image_tag "${IMAGE_PAPERMANTRA}")",
    "website": "$(image_tag "${IMAGE_ROBOFUME}")",
    "api": "$(image_tag "${IMAGE_SERVICES}")",
    "pdf": "$(image_tag "${IMAGE_PDF}")"
  },
  "running": {
    "portal": "$(image_tag "${portal_img}")",
    "website": "$(image_tag "${website_img}")",
    "api": "$(image_tag "${api_img}")",
    "pdf": "$(image_tag "${pdf_img}")"
  },
  "images": {
    "portal": "${portal_img}",
    "website": "${website_img}",
    "api": "${api_img}",
    "pdf": "${pdf_img}"
  }
}
EOF
mv -f "${META_FILE}.tmp" "${META_FILE}"
echo ">> Wrote ${META_FILE}"
