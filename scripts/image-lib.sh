#!/usr/bin/env bash
# Shared helpers for image-sync / image-replace (local + optional VPS deploy).
set -euo pipefail

image_lib_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd
}

image_lib_load_config() {
  local root
  root="$(image_lib_root)"
  local config="${root}/scripts/sync-data.config"
  if [[ -f "${config}" ]]; then
    # shellcheck disable=SC1090
    source "${config}"
  fi
  PAPERMANTRA_SERVICES_ROOT="${PAPERMANTRA_SERVICES_ROOT:-}"
  PDFGENERATOR_ROOT="${PDFGENERATOR_ROOT:-}"
  VPS_HOST="${VPS_HOST:-}"
  VPS_USER="${VPS_USER:-deploy}"
  VPS_PATH="${VPS_PATH:-/opt/papermantra-infra}"
  SSH_KEY="${SSH_KEY:-}"
}

image_lib_resolve_paths() {
  image_lib_load_config

  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
  local repo_root
  repo_root="$(cd "${script_dir}/.." && pwd)"
  local repo_name
  repo_name="$(basename "${repo_root}")"

  if [[ -z "${PAPERMANTRA_SERVICES_ROOT}" ]]; then
    case "${repo_name}" in
      papermantraservices) PAPERMANTRA_SERVICES_ROOT="${repo_root}" ;;
      pdfgenerator)
        if [[ -d "${repo_root}/../papermantraservices" ]]; then
          PAPERMANTRA_SERVICES_ROOT="$(cd "${repo_root}/../papermantraservices" && pwd)"
        fi
        ;;
    esac
  fi

  if [[ -z "${PDFGENERATOR_ROOT}" ]]; then
    case "${repo_name}" in
      pdfgenerator) PDFGENERATOR_ROOT="${repo_root}" ;;
      papermantraservices)
        if [[ -d "${repo_root}/../pdfgenerator" ]]; then
          PDFGENERATOR_ROOT="$(cd "${repo_root}/../pdfgenerator" && pwd)"
        fi
        ;;
    esac
  fi

  IMAGE_SOURCE_DIR="${PAPERMANTRA_SERVICES_ROOT}/images"
  IMAGE_TARGET_DIR="${PDFGENERATOR_ROOT}/images"
}

image_lib_ensure_dirs() {
  mkdir -p "${IMAGE_SOURCE_DIR}" "${IMAGE_TARGET_DIR}"
}

image_lib_rsync_incremental() {
  local source="$1"
  local target="$2"
  local dry_run="${3:-0}"

  if command -v rsync >/dev/null 2>&1; then
    local flags=(-a --checksum --itemize-changes)
    [[ "${dry_run}" -eq 1 ]] && flags+=(-n)
    rsync "${flags[@]}" "${source}/" "${target}/"
    return
  fi

  # Fallback without rsync (Git Bash on Windows): copy only new or size/mtime-different files
  local src_file rel dest
  while IFS= read -r -d '' src_file; do
    rel="${src_file#"${source}/"}"
    dest="${target}/${rel}"
    if [[ ! -f "${dest}" ]] || [[ "$(stat -c '%s' "${src_file}" 2>/dev/null || stat -f '%z' "${src_file}")" != "$(stat -c '%s' "${dest}" 2>/dev/null || stat -f '%z' "${dest}")" ]]; then
      if [[ "${dry_run}" -eq 1 ]]; then
        echo ">f+++++++ ${rel}"
      else
        mkdir -p "$(dirname "${dest}")"
        cp -p "${src_file}" "${dest}"
        echo "copied: ${rel}"
      fi
    fi
  done < <(find "${source}" -type f -print0)
}

image_lib_rsync_replace() {
  local source="$1"
  local target="$2"
  local dry_run="${3:-0}"

  if [[ "${dry_run}" -eq 1 ]]; then
    echo "[dry-run] would replace all files in ${target} from ${source}"
    image_lib_rsync_incremental "${source}" "${target}" 1
    return
  fi

  mkdir -p "${target}"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete "${source}/" "${target}/"
  else
    find "${target}" -mindepth 1 -delete 2>/dev/null || rm -rf "${target:?}"/*
    image_lib_rsync_incremental "${source}" "${target}" 0
  fi
}

image_lib_count_files() {
  find "$1" -type f 2>/dev/null | wc -l | tr -d ' \r'
}

image_lib_deploy_to_vps() {
  local mode="$1"   # sync | replace
  local dry_run="${2:-0}"

  if [[ -z "${VPS_HOST}" || -z "${SSH_KEY}" ]]; then
    echo "ERROR: VPS_HOST and SSH_KEY required in scripts/sync-data.config for --deploy"
    exit 1
  fi

  local remote="${VPS_USER}@${VPS_HOST}"
  local staging="${VPS_PATH}/images"
  local ssh_opts=(-o BatchMode=yes -i "${SSH_KEY}")

  echo ">> Deploy (${mode}) → ${remote}:${staging}"

  if [[ "${dry_run}" -eq 1 ]]; then
    echo "   [dry-run] would upload ${IMAGE_SOURCE_DIR} and run VPS image-${mode}"
    return
  fi

  ssh "${ssh_opts[@]}" "${remote}" "mkdir -p '${staging}'"
  if command -v rsync >/dev/null 2>&1; then
    rsync -az --delete-after -e "ssh -o BatchMode=yes -i ${SSH_KEY}" \
      "${IMAGE_SOURCE_DIR}/" "${remote}:${staging}/"
  else
    scp "${ssh_opts[@]}" -r "${IMAGE_SOURCE_DIR}/." "${remote}:${staging}/"
  fi

  local remote_cmd="cd '${VPS_PATH}' && git pull origin main && chmod +x scripts/*.sh && ./scripts/sync-question-images.sh --source '${staging}'"
  if [[ "${mode}" == "replace" ]]; then
    remote_cmd="${remote_cmd} --replace"
  fi
  ssh "${ssh_opts[@]}" "${remote}" "${remote_cmd}"
}
