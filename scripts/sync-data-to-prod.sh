#!/usr/bin/env bash
# =============================================================================
# Sync local MongoDB + question images to production VPS (bash/WSL/macOS).
#
# Setup:
#   cp scripts/sync-data.config.example scripts/sync-data.config
#   edit paths in sync-data.config
#
# Usage:
#   ./scripts/sync-data-to-prod.sh
#   ./scripts/sync-data-to-prod.sh --skip-mongo
#   ./scripts/sync-data-to-prod.sh --skip-images
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${ROOT_DIR}/scripts/sync-data.config"
SKIP_MONGO=0
SKIP_IMAGES=0

for arg in "$@"; do
  case "${arg}" in
    --skip-mongo) SKIP_MONGO=1 ;;
    --skip-images) SKIP_IMAGES=1 ;;
  esac
done

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

if [[ "${SKIP_MONGO}" -eq 0 ]]; then
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
fi

if [[ "${SKIP_IMAGES}" -eq 0 ]]; then
  echo ">> Copying image folders..."
  cp -a "${PAPERMANTRA_SERVICES_ROOT}/images" "${STAGING_LOCAL}/api-images"
  cp -a "${PAPERMANTRA_SERVICES_ROOT}/userPic" "${STAGING_LOCAL}/api-userPic"
  cp -a "${PDFGENERATOR_ROOT}/images" "${STAGING_LOCAL}/pdf-images"
fi

echo ">> Uploading to ${REMOTE}:${STAGING_REMOTE} ..."
ssh "${SSH_OPTS[@]}" "${REMOTE}" "mkdir -p '${STAGING_REMOTE}'"
scp "${SSH_OPTS[@]}" -r "${STAGING_LOCAL}/." "${REMOTE}:${STAGING_REMOTE}/"

FLAGS=()
[[ "${SKIP_MONGO}" -eq 1 ]] && FLAGS+=(--skip-mongo)
[[ "${SKIP_IMAGES}" -eq 1 ]] && FLAGS+=(--skip-images)

echo ">> Running restore on VPS..."
ssh "${SSH_OPTS[@]}" "${REMOTE}" \
  "cd '${VPS_PATH}' && git pull origin main && chmod +x scripts/restore-data-on-vps.sh && ./scripts/restore-data-on-vps.sh ${FLAGS[*]:-}"

echo ">> Sync complete."
