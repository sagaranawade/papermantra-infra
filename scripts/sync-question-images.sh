#!/usr/bin/env bash
# =============================================================================
# Sync question images from the VPS staging folder into the shared Docker volume
# used by both api and pdf at /app/images.
#
# IMPORTANT (prod layout):
#   papermantra-api  AND  papermantra-pdf both mount ONE volume:
#     papermantra_question_images  →  /app/images
#   There are NOT two live image volumes. One sync updates both services.
#   (Legacy volumes papermantra_api_question_images / papermantra_pdf_images
#    are unused leftovers and must not be targeted.)
#
# STAGING (/opt/papermantra-infra/images) is READ-ONLY for this script — files here
# are never deleted. Only the Docker volume may be wiped with --replace.
#
# Default (no flags): MERGE + OVERWRITE
#   - Copy new files from staging → volume
#   - If the same relative path already exists in the volume, REPLACE it when
#     content differs (rsync --checksum)
#   - Files that exist only in the volume are kept
#
# Prefer from your PC:
#   papermantra-infra/scripts/image-sync.ps1 -Deploy      # merge+overwrite
#   papermantra-infra/scripts/image-replace.ps1 -Deploy   # wipe volume, then copy all
#
# Or upload with WinSCP → /opt/papermantra-infra/images/ then run this on VPS.
#
# Usage:
#   ./scripts/sync-question-images.sh              # merge + overwrite existing
#   ./scripts/sync-question-images.sh --dry-run    # show what would copy
#   ./scripts/sync-question-images.sh --replace    # wipe volume, then copy all
#   ./scripts/sync-question-images.sh --source /path/to/other/folder
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

SOURCE_DIR="${ROOT_DIR}/images"
TARGET_VOL="papermantra_question_images"
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
      sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
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
  echo "       Upload images with WinSCP first, then run this script again."
  exit 1
fi

staging_count="$(find "${SOURCE_DIR}" -type f 2>/dev/null | wc -l | tr -d ' ')"
echo ">> Staging folder: ${SOURCE_DIR} (${staging_count} file(s))"
echo ">> Target volume:  ${TARGET_VOL} → /app/images in api + pdf (shared)"

docker volume create "${TARGET_VOL}" >/dev/null

if [[ "${REPLACE}" -eq 1 ]]; then
  echo ">> FULL REPLACE: wiping ALL files in ${TARGET_VOL}, then copying staging..."
  echo "   WARNING: volume-only files (not in staging) will be deleted."
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo "   [dry-run] would delete volume contents and copy from staging"
  else
    docker run --rm \
      -v "${TARGET_VOL}:/target" \
      alpine:3.20 \
      sh -c 'rm -rf /target/* /target/.[!.]* /target/..?* 2>/dev/null || true'
  fi
else
  echo ">> MERGE+OVERWRITE: new files copied; same-path files replaced when content differs."
  echo "   Volume-only files are kept."
fi

# --checksum: replace same-path files when content differs (not only size/mtime)
if [[ "${DRY_RUN}" -eq 1 ]]; then
  docker run --rm \
    -v "${SOURCE_DIR}:/source:ro" \
    -v "${TARGET_VOL}:/target" \
    alpine:3.20 \
    sh -c 'apk add --no-cache rsync >/dev/null && rsync -avhn --checksum --itemize-changes /source/ /target/'
  echo ">> Dry run complete. Re-run without --dry-run to apply."
  exit 0
fi

docker run --rm \
  -v "${SOURCE_DIR}:/source:ro" \
  -v "${TARGET_VOL}:/target" \
  alpine:3.20 \
  sh -c 'apk add --no-cache rsync >/dev/null && rsync -a --checksum --itemize-changes /source/ /target/'

echo ">> Fixing permissions (readable/writable by api + pdf)..."
docker run --rm \
  -v "${TARGET_VOL}:/data" \
  alpine:3.20 \
  sh -c 'chmod -R a+rwX /data'

api_count="$(docker compose exec -T api sh -c 'find /app/images -type f 2>/dev/null | wc -l' | tr -d ' \r')"
pdf_count="$(docker compose exec -T pdf sh -c 'find /app/images -type f 2>/dev/null | wc -l' | tr -d ' \r')"

echo ">> Sync complete."
echo "   api /app/images: ${api_count} file(s)"
echo "   pdf /app/images: ${pdf_count} file(s)"
echo "   (counts should match — same shared volume)"

if [[ "${api_count}" != "${pdf_count}" ]]; then
  echo "WARN: file counts differ; run ./scripts/verify-datastores.sh"
  exit 1
fi
