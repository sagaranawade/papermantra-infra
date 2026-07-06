#!/usr/bin/env bash
# =============================================================================
# Restore MongoDB from .sync-staging/ (run ON the VPS).
# Called by sync-data-to-prod.ps1 / sync-data-to-prod.sh
#
# Usage:
#   ./scripts/restore-data-on-vps.sh
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

STAGING="${ROOT_DIR}/.sync-staging"

if [[ ! -f .env ]]; then
  echo "ERROR: .env not found in ${ROOT_DIR}"
  exit 1
fi

# shellcheck disable=SC1091
source .env

if [[ ! -d "${STAGING}" ]]; then
  echo "ERROR: staging dir missing: ${STAGING}"
  exit 1
fi

restore_mongo() {
  local archive="$1"
  local db="$2"
  if [[ ! -f "${archive}" ]]; then
    echo "WARN: missing ${archive}, skipping ${db}"
    return 0
  fi
  echo ">> Restoring MongoDB database: ${db}"
  docker compose exec -T mongodb mongorestore \
    --username="${MONGO_ROOT_USER}" \
    --password="${MONGO_ROOT_PASSWORD}" \
    --authenticationDatabase=admin \
    --archive \
    --gzip \
    --drop \
    --nsInclude="${db}.*" \
    < "${archive}"
}

restore_mongo "${STAGING}/papermantra.archive.gz" "${MONGODB_DATABASE:-papermantra}"
restore_mongo "${STAGING}/pdfgenerator.archive.gz" "${PDF_MONGODB_DATABASE:-pdfgenerator}"

echo ">> Restarting api and pdf..."
docker compose restart api pdf

echo ">> Restore complete."
echo "   Verify: docker compose exec mongodb mongosh -u \"\${MONGO_ROOT_USER}\" -p \"\${MONGO_ROOT_PASSWORD}\" --authenticationDatabase admin --eval \"db.getSiblingDB('papermantra').stats().collections\""
