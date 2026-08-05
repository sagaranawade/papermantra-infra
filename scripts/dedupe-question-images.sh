#!/usr/bin/env bash
# =============================================================================
# dedupe-question-images.sh — thin wrapper around dedupe_question_images.py
#
# When the same basename exists as both PNG and JPG/JPEG, keep PNG and
# quarantine (or delete) the JPG/JPEG twin.
#
# Usage:
#   ./scripts/dedupe-question-images.sh --dir /path/to/images --dry-run
#   ./scripts/dedupe-question-images.sh --staging --apply
#   ./scripts/dedupe-question-images.sh --volume papermantra_question_images --apply
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="${ROOT_DIR}/scripts"
PY="${SCRIPT_DIR}/dedupe_question_images.py"

MODE="--dry-run"
HARD_DELETE=0
TARGET_DIR=""
TARGET_VOLUME=""
LABEL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) MODE="--dry-run" ;;
    --apply) MODE="--apply" ;;
    --delete) HARD_DELETE=1 ;;
    --dir)
      shift
      [[ $# -gt 0 ]] || { echo "ERROR: --dir requires a path"; exit 1; }
      TARGET_DIR="$1"
      ;;
    --dir=*) TARGET_DIR="${1#--dir=}" ;;
    --volume)
      shift
      [[ $# -gt 0 ]] || { echo "ERROR: --volume requires a name"; exit 1; }
      TARGET_VOLUME="$1"
      ;;
    --volume=*) TARGET_VOLUME="${1#--volume=}" ;;
    --staging) TARGET_DIR="${ROOT_DIR}/images"; LABEL="staging" ;;
    --label)
      shift
      LABEL="$1"
      ;;
    -h|--help)
      sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "ERROR: unknown argument: $1"; exit 1 ;;
  esac
  shift
done

if [[ -z "${TARGET_DIR}" && -z "${TARGET_VOLUME}" ]]; then
  echo "ERROR: pass --dir PATH, --staging, or --volume NAME"
  exit 1
fi
if [[ -n "${TARGET_DIR}" && -n "${TARGET_VOLUME}" ]]; then
  echo "ERROR: pass only one of --dir/--staging or --volume"
  exit 1
fi

py_bin() {
  if command -v python3 >/dev/null 2>&1; then echo python3
  elif command -v python >/dev/null 2>&1; then echo python
  else echo "ERROR: python3/python not found"; exit 1
  fi
}

run_dir() {
  local dir="$1"
  local label="${LABEL:-$(basename "${dir}")}"
  local report_dir="${ROOT_DIR}/Image_Dedupe_Reports"
  mkdir -p "${report_dir}"
  local args=("${PY}" --dir "${dir}" "${MODE}" --label "${label}" --report "${report_dir}/dedupe_${label}_$(date +%Y%m%d_%H%M%S).json")
  [[ "${HARD_DELETE}" -eq 1 ]] && args+=(--delete)
  echo ">> $(py_bin) ${args[*]}"
  "$(py_bin)" "${args[@]}"
}

run_volume() {
  local vol="$1"
  local label="${LABEL:-volume}"
  local report_dir="${ROOT_DIR}/Image_Dedupe_Reports"
  mkdir -p "${report_dir}"
  local stamp
  stamp="$(date +%Y%m%d_%H%M%S)"
  local report_name="dedupe_${label}_${stamp}.json"

  if ! docker volume inspect "${vol}" >/dev/null 2>&1; then
    echo "ERROR: docker volume not found: ${vol}"
    exit 1
  fi

  local mode_flag="--dry-run"
  [[ "${MODE}" == "--apply" ]] && mode_flag="--apply"
  local delete_args=()
  [[ "${HARD_DELETE}" -eq 1 ]] && delete_args=(--delete)

  echo ">> Dedupe on Docker volume ${vol} (${mode_flag})"
  docker run --rm \
    -v "${vol}:/data" \
    -v "${PY}:/dedupe.py:ro" \
    -v "${report_dir}:/reports" \
    python:3.12-alpine \
    python /dedupe.py --dir /data "${mode_flag}" "${delete_args[@]}" --label "${label}" --report "/reports/${report_name}"

  if [[ "${MODE}" == "--apply" ]]; then
    docker run --rm -v "${vol}:/data" alpine:3.20 sh -c 'chmod -R a+rwX /data'
  fi
  echo ">> Volume report: ${report_dir}/${report_name}"
}

if [[ -n "${TARGET_DIR}" ]]; then
  run_dir "${TARGET_DIR}"
else
  run_volume "${TARGET_VOLUME}"
fi
