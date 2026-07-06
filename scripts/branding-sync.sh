#!/usr/bin/env bash
# =============================================================================
# branding-sync — copy local papermantraservices/user-uploads to prod (optional)
#
# Usage:
#   ./scripts/branding-sync.sh
#   ./scripts/branding-sync.sh --dry-run
#   ./scripts/branding-sync.sh --deploy
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
      sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "ERROR: unknown argument: $1"; exit 1 ;;
  esac
  shift
done

image_lib_resolve_paths

if [[ -z "${PAPERMANTRA_SERVICES_ROOT}" ]]; then
  echo "ERROR: Set PAPERMANTRA_SERVICES_ROOT in scripts/sync-data.config"
  exit 1
fi

BRANDING_SOURCE_DIR="${PAPERMANTRA_SERVICES_ROOT}/user-uploads"
BRANDING_STAGING_DIR="$(image_lib_root)/user-uploads"

mkdir -p "${BRANDING_STAGING_DIR}"

src_count="$(image_lib_count_files "${BRANDING_SOURCE_DIR}")"
echo ">> branding-sync (incremental)"
echo "   source: ${BRANDING_SOURCE_DIR} (${src_count} files)"
echo "   staging: ${BRANDING_STAGING_DIR}"

if [[ "${src_count}" -eq 0 ]]; then
  echo "WARN: source user-uploads folder is empty — nothing to sync"
else
  image_lib_rsync_incremental "${BRANDING_SOURCE_DIR}" "${BRANDING_STAGING_DIR}" "${DRY_RUN}"
fi

if [[ "${DEPLOY}" -eq 1 ]]; then
  if [[ -z "${VPS_HOST}" || -z "${SSH_KEY}" ]]; then
    echo "ERROR: VPS_HOST and SSH_KEY required in scripts/sync-data.config for --deploy"
    exit 1
  fi

  remote="${VPS_USER}@${VPS_HOST}"
  staging="${VPS_PATH}/user-uploads"
  ssh_opts=(-o BatchMode=yes -i "${SSH_KEY}")

  echo ">> Deploy → ${remote}:${staging}"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo "   [dry-run] would upload and run sync-branding-uploads.sh on VPS"
    exit 0
  fi

  ssh "${ssh_opts[@]}" "${remote}" "mkdir -p '${staging}'"
  if command -v rsync >/dev/null 2>&1; then
    rsync -az --checksum -e "ssh -o BatchMode=yes -i ${SSH_KEY}" \
      "${BRANDING_STAGING_DIR}/" "${remote}:${staging}/"
  else
    scp "${ssh_opts[@]}" -r "${BRANDING_STAGING_DIR}/." "${remote}:${staging}/"
  fi

  ssh "${ssh_opts[@]}" "${remote}" \
    "cd '${VPS_PATH}' && git pull origin main && chmod +x scripts/*.sh && ./scripts/sync-branding-uploads.sh --source '${staging}'"
  echo ">> VPS branding deploy complete"
fi
