#!/usr/bin/env bash
# =============================================================================
# image-sync — copy only new/changed question images (source of truth: papermantraservices/images)
#
# Updates pdfgenerator/images locally. Optional --deploy pushes to VPS shared volume.
#
# Usage:
#   ./scripts/image-sync.sh
#   ./scripts/image-sync.sh --dry-run
#   ./scripts/image-sync.sh --deploy
#
# Config (optional): scripts/sync-data.config
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=image-lib.sh
source "${SCRIPT_DIR}/image-lib.sh"

DRY_RUN=0
DEPLOY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --deploy) DEPLOY=1 ;;
    -h|--help)
      sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "ERROR: unknown argument: $1"; exit 1 ;;
  esac
  shift
done

image_lib_resolve_paths

if [[ -z "${PAPERMANTRA_SERVICES_ROOT}" || -z "${PDFGENERATOR_ROOT}" ]]; then
  echo "ERROR: Set PAPERMANTRA_SERVICES_ROOT and PDFGENERATOR_ROOT in scripts/sync-data.config"
  exit 1
fi

image_lib_ensure_dirs

src_count="$(image_lib_count_files "${IMAGE_SOURCE_DIR}")"
echo ">> image-sync (incremental)"
echo "   source: ${IMAGE_SOURCE_DIR} (${src_count} files)"
echo "   target: ${IMAGE_TARGET_DIR}"

if [[ "${src_count}" -eq 0 ]]; then
  echo "WARN: source folder is empty — nothing to sync"
else
  echo ">> Comparing and copying new/changed files..."
  image_lib_rsync_incremental "${IMAGE_SOURCE_DIR}" "${IMAGE_TARGET_DIR}" "${DRY_RUN}"
  tgt_count="$(image_lib_count_files "${IMAGE_TARGET_DIR}")"
  echo ">> Local sync done. target now has ${tgt_count} file(s)"
fi

if [[ "${DEPLOY}" -eq 1 ]]; then
  image_lib_deploy_to_vps sync "${DRY_RUN}"
  echo ">> VPS deploy complete (merge into shared /app/images volume)"
fi
