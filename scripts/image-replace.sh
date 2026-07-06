#!/usr/bin/env bash
# =============================================================================
# image-replace — wipe target and copy all images from papermantraservices/images
#
# Local: replaces pdfgenerator/images only (not VPS staging).
# Prod (--deploy): upload merge to VPS staging, then --replace on Docker volume only.
#
# Usage:
#   ./scripts/image-replace.sh
#   ./scripts/image-replace.sh --dry-run
#   ./scripts/image-replace.sh --deploy
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
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
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
echo ">> image-replace (full copy)"
echo "   source: ${IMAGE_SOURCE_DIR} (${src_count} files)"
echo "   target: ${IMAGE_TARGET_DIR} (will be replaced)"

if [[ "${src_count}" -eq 0 ]]; then
  echo "ERROR: source folder is empty — refusing to replace target with nothing"
  exit 1
fi

echo ">> Replacing local pdfgenerator/images..."
image_lib_rsync_replace "${IMAGE_SOURCE_DIR}" "${IMAGE_TARGET_DIR}" "${DRY_RUN}"
tgt_count="$(image_lib_count_files "${IMAGE_TARGET_DIR}")"
echo ">> Local replace done. target now has ${tgt_count} file(s)"

if [[ "${DEPLOY}" -eq 1 ]]; then
  image_lib_deploy_to_vps replace "${DRY_RUN}"
  echo ">> VPS replace complete (shared /app/images volume)"
fi
