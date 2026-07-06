#!/usr/bin/env bash
# =============================================================================
# Restore MongoDB from .sync-staging/ (run ON the VPS).
# MongoDB ONLY — does not touch image volumes.
#
# Safety: refuses archives smaller than MIN_ARCHIVE_BYTES to prevent wiping
# production with an empty dump.
#
# Usage:
#   ./scripts/restore-data-on-vps.sh
#   ./scripts/restore-data-on-vps.sh --force   # skip size check (dangerous)
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

STAGING="${ROOT_DIR}/.sync-staging"
MIN_ARCHIVE_BYTES=1024
FORCE=0

for arg in "$@"; do
  case "${arg}" in
    --force) FORCE=1 ;;
    --skip-mongo) echo "ERROR: --skip-mongo is not supported (this script is mongo-only)"; exit 1 ;;
    --skip-images) ;; # accepted for backward compatibility; images are never touched
    -h|--help)
      sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: ${arg}"
      exit 1
      ;;
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

assert_archive_ok() {
  local archive="$1"
  local label="$2"
  if [[ ! -f "${archive}" ]]; then
    echo "ERROR: missing archive for ${label}: ${archive}"
    exit 1
  fi
  local size
  size="$(wc -c < "${archive}" | tr -d ' ')"
  if [[ "${FORCE}" -eq 0 && "${size}" -lt "${MIN_ARCHIVE_BYTES}" ]]; then
    echo "ERROR: ${label} archive is only ${size} bytes (${archive})."
    echo "       Refusing to run mongorestore --drop — this would wipe production data."
    echo "       Upload a valid dump or pass --force (not recommended)."
    exit 1
  fi
  echo "   ${label}: ${size} bytes"
}

restore_mongo() {
  local archive="$1"
  local db="$2"
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

echo ">> Validating archives (min ${MIN_ARCHIVE_BYTES} bytes)..."
assert_archive_ok "${STAGING}/papermantra.archive.gz" "papermantra"
assert_archive_ok "${STAGING}/pdfgenerator.archive.gz" "pdfgenerator"

restore_mongo "${STAGING}/papermantra.archive.gz" "${MONGODB_DATABASE:-papermantra}"
restore_mongo "${STAGING}/pdfgenerator.archive.gz" "${PDF_MONGODB_DATABASE:-pdfgenerator}"

echo ">> Restarting api and pdf..."
docker compose restart api pdf

echo ">> MongoDB restore complete (images not modified)."
echo "   Verify: docker compose exec mongodb mongosh -u \"\${MONGO_ROOT_USER}\" -p \"\${MONGO_ROOT_PASSWORD}\" --authenticationDatabase admin --eval \"db.getSiblingDB('papermantra').login_info.countDocuments()\""
