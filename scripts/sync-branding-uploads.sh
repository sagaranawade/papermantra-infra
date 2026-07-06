#!/usr/bin/env bash
# =============================================================================
# Sync institution branding files (user-uploads) into the API Docker volume.
#
# STAGING (/opt/papermantra-infra/user-uploads) is merge-only — never deleted.
# Target: papermantra_api_user_uploads → /app/user-uploads in papermantra-api
#
# Upload from your PC:
#   papermantra-infra/scripts/branding-sync.ps1 -Deploy
#
# Or WinSCP → /opt/papermantra-infra/user-uploads/ then run this on VPS.
#
# Usage:
#   ./scripts/sync-branding-uploads.sh
#   ./scripts/sync-branding-uploads.sh --dry-run
#   ./scripts/sync-branding-uploads.sh --replace
#   ./scripts/sync-branding-uploads.sh --source /path/to/user-uploads
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

SOURCE_DIR="${ROOT_DIR}/user-uploads"
TARGET_VOL="papermantra_api_user_uploads"
DRY_RUN=0
REPLACE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --replace) REPLACE=1 ;;
    --source)
      shift
      [[ $# -gt 0 ]] || { echo "ERROR: --source requires a path"; exit 1; }
      SOURCE_DIR="$1"
      ;;
    --source=*) SOURCE_DIR="${1#--source=}" ;;
    -h|--help)
      sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1"
      exit 1
      ;;
  esac
  shift
done

if [[ ! -d "${SOURCE_DIR}" ]]; then
  echo ">> Creating staging folder: ${SOURCE_DIR}"
  mkdir -p "${SOURCE_DIR}"
fi

if [[ -z "$(ls -A "${SOURCE_DIR}" 2>/dev/null || true)" ]]; then
  echo "ERROR: staging folder is empty: ${SOURCE_DIR}"
  echo "       Copy local papermantraservices/user-uploads here, or run branding-sync.ps1 -Deploy"
  exit 1
fi

staging_count="$(find "${SOURCE_DIR}" -type f 2>/dev/null | wc -l | tr -d ' ')"
echo ">> Staging folder: ${SOURCE_DIR} (${staging_count} file(s))"
echo ">> Target volume:  ${TARGET_VOL} → /app/user-uploads in api"

docker volume create "${TARGET_VOL}" >/dev/null

if [[ "${REPLACE}" -eq 1 ]]; then
  echo ">> Replacing all files in ${TARGET_VOL}..."
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo "   [dry-run] would delete volume contents and copy from staging"
  else
    docker run --rm \
      -v "${TARGET_VOL}:/target" \
      alpine:3.20 \
      sh -c 'rm -rf /target/* /target/.[!.]* /target/..?* 2>/dev/null || true'
  fi
fi

echo ">> Syncing branding uploads (merge)..."
if [[ "${DRY_RUN}" -eq 1 ]]; then
  docker run --rm \
    -v "${SOURCE_DIR}:/source:ro" \
    -v "${TARGET_VOL}:/target" \
    alpine:3.20 \
    sh -c 'apk add --no-cache rsync >/dev/null && rsync -avhn --itemize-changes /source/ /target/'
  echo ">> Dry run complete."
  exit 0
fi

docker run --rm \
  -v "${SOURCE_DIR}:/source:ro" \
  -v "${TARGET_VOL}:/target" \
  alpine:3.20 \
  sh -c 'apk add --no-cache rsync >/dev/null && rsync -a /source/ /target/'

echo ">> Fixing permissions..."
docker run --rm \
  -v "${TARGET_VOL}:/data" \
  alpine:3.20 \
  sh -c 'chmod -R a+rwX /data'

api_count="$(docker compose exec -T api sh -c 'find /app/user-uploads -type f 2>/dev/null | wc -l' | tr -d ' \r')"
echo ">> Sync complete. api /app/user-uploads: ${api_count} file(s)"
