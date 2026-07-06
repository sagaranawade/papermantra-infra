#!/usr/bin/env bash
# =============================================================================
# Restore MongoDB + images from .sync-staging/ (run ON the VPS).
# Called by sync-data-to-prod.ps1 / sync-data-to-prod.sh
#
# Usage:
#   ./scripts/restore-data-on-vps.sh
#   ./scripts/restore-data-on-vps.sh --skip-mongo
#   ./scripts/restore-data-on-vps.sh --skip-images
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

STAGING="${ROOT_DIR}/.sync-staging"
SKIP_MONGO=0
SKIP_IMAGES=0

for arg in "$@"; do
  case "${arg}" in
    --skip-mongo) SKIP_MONGO=1 ;;
    --skip-images) SKIP_IMAGES=1 ;;
  esac
done

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

API_UID="${API_UID:-100}"
API_GID="${API_GID:-101}"
PDF_UID="${PDF_UID:-999}"
PDF_GID="${PDF_GID:-999}"

echo ">> Recreating api/pdf with corrected volume mounts..."
docker compose up -d --force-recreate api pdf

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

copy_tree_to_volume() {
  local src="$1"
  local volume="$2"
  local uid="$3"
  local gid="$4"
  if [[ ! -d "${src}" ]]; then
    echo "WARN: missing ${src}, skipping volume ${volume}"
    return 0
  fi
  echo ">> Copying ${src} → volume ${volume}"
  docker run --rm \
    -v "${volume}:/target" \
    -v "${src}:/source:ro" \
    alpine:3.20 \
    sh -c "rm -rf /target/* && cp -a /source/. /target/ && chown -R ${uid}:${gid} /target"
}

if [[ "${SKIP_MONGO}" -eq 0 ]]; then
  restore_mongo "${STAGING}/papermantra.archive.gz" "${MONGODB_DATABASE:-papermantra}"
  restore_mongo "${STAGING}/pdfgenerator.archive.gz" "${PDF_MONGODB_DATABASE:-pdfgenerator}"
fi

if [[ "${SKIP_IMAGES}" -eq 0 ]]; then
  copy_tree_to_volume "${STAGING}/api-images" "papermantra_question_images" "${API_UID}" "${PDF_GID}"
  copy_tree_to_volume "${STAGING}/api-userPic" "papermantra_api_user_pics" "${API_UID}" "${API_GID}"
  # pdf reads the same shared images volume as api (no separate pdf-images copy)
  docker run --rm \
    -v papermantra_question_images:/data \
    alpine:3.20 \
    sh -c "chmod -R a+rwX /data"
fi

echo ">> Restarting api and pdf..."
docker compose restart api pdf

echo ">> Restore complete."
echo "   Verify: docker compose exec api ls /app/images | head"
echo "   Verify: docker compose exec pdf ls /app/images | head"
