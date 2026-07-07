#!/usr/bin/env bash
# Update a single IMAGE_* line in .env (used before deploy or rollback).
#
# Usage:
#   ./scripts/update-image-tag.sh IMAGE_SERVICES v1.4.0
#   ./scripts/update-image-tag.sh IMAGE_PAPERMANTRA latest
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

KEY="${1:?IMAGE env key required, e.g. IMAGE_SERVICES}"
TAG="${2:?Tag required, e.g. v1.4.0 or latest}"

if [[ ! -f .env ]]; then
  echo "ERROR: .env not found."
  exit 1
fi

# shellcheck disable=SC1091
source .env

REGISTRY="${REGISTRY:-ghcr.io}"
OWNER="${REGISTRY_OWNER:-sagaranawade}"

case "${KEY}" in
  IMAGE_PAPERMANTRA)  BASE="${REGISTRY}/${OWNER}/papermantra" ;;
  IMAGE_ROBOFUME)     BASE="${REGISTRY}/${OWNER}/robofume" ;;
  IMAGE_SERVICES)     BASE="${REGISTRY}/${OWNER}/papermantraservices" ;;
  IMAGE_PDF)          BASE="${REGISTRY}/${OWNER}/pdf-generator" ;;
  *)
    echo "ERROR: Unknown key ${KEY}. Use IMAGE_PAPERMANTRA, IMAGE_ROBOFUME, IMAGE_SERVICES, or IMAGE_PDF."
    exit 1
    ;;
esac

NEW_VALUE="${BASE}:${TAG}"

if grep -q "^${KEY}=" .env; then
  sed -i.bak "s|^${KEY}=.*|${KEY}=${NEW_VALUE}|" .env
  rm -f .env.bak
else
  echo "${KEY}=${NEW_VALUE}" >> .env
fi

echo "Updated ${KEY}=${NEW_VALUE}"
