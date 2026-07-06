#!/usr/bin/env bash
# =============================================================================
# Sync local MongoDB databases to production VPS (bash/WSL/macOS).
#
# Setup:
#   cp scripts/sync-data.config.example scripts/sync-data.config
#   edit paths in sync-data.config
#
# Usage:
#   ./scripts/sync-data-to-prod.sh
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${ROOT_DIR}/scripts/sync-data.config"

if [[ ! -f "${CONFIG}" ]]; then
  echo "ERROR: missing ${CONFIG} (copy sync-data.config.example)"
  exit 1
fi

# shellcheck disable=SC1090
source "${CONFIG}"

SSH_OPTS=(-o BatchMode=yes -i "${SSH_KEY}")
REMOTE="${VPS_USER}@${VPS_HOST}"
STAGING_LOCAL="$(mktemp -d /tmp/papermantra-sync-XXXXXX)"
STAGING_REMOTE="${VPS_PATH}/.sync-staging"

cleanup() { rm -rf "${STAGING_LOCAL}"; }
trap cleanup EXIT

echo ">> Local staging: ${STAGING_LOCAL}"

echo ">> Dumping MongoDB: ${PAPERMANTRA_DB}"
docker run --rm \
  --add-host=host.docker.internal:host-gateway \
  -v "${STAGING_LOCAL}:/backup" \
  mongo:7.0 \
  mongodump --host="${LOCAL_MONGO_HOST}" --port="${LOCAL_MONGO_PORT}" \
    --db="${PAPERMANTRA_DB}" --archive=/backup/papermantra.archive.gz --gzip

echo ">> Dumping MongoDB: ${PDFGENERATOR_DB}"
docker run --rm \
  --add-host=host.docker.internal:host-gateway \
  -v "${STAGING_LOCAL}:/backup" \
  mongo:7.0 \
  mongodump --host="${LOCAL_MONGO_HOST}" --port="${LOCAL_MONGO_PORT}" \
    --db="${PDFGENERATOR_DB}" --archive=/backup/pdfgenerator.archive.gz --gzip

echo ">> Uploading to ${REMOTE}:${STAGING_REMOTE} ..."
ssh "${SSH_OPTS[@]}" "${REMOTE}" "mkdir -p '${STAGING_REMOTE}'"
scp "${SSH_OPTS[@]}" \
  "${STAGING_LOCAL}/papermantra.archive.gz" \
  "${STAGING_LOCAL}/pdfgenerator.archive.gz" \
  "${REMOTE}:${STAGING_REMOTE}/"

echo ">> Running restore on VPS..."
ssh "${SSH_OPTS[@]}" "${REMOTE}" \
  "cd '${VPS_PATH}' && git pull origin main && chmod +x scripts/restore-data-on-vps.sh && ./scripts/restore-data-on-vps.sh"

echo ">> Sync complete."
