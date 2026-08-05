#!/usr/bin/env bash
# =============================================================================
# vps-dedupe-question-images.sh
#
# Standalone VPS tool — does NOT use or compare anything on your local PC.
#
# Checks / cleans duplicate basenames under question images where the same
# name exists as both PNG and JPG/JPEG. PNG always wins.
#
# On prod, api + pdf share one Docker volume (papermantra_question_images)
# mounted at /app/images — so one volume pass covers both services.
# Staging folder /opt/papermantra-infra/images is cleaned separately.
#
# Usage (on VPS, from /opt/papermantra-infra):
#   ./scripts/vps-dedupe-question-images.sh              # dry-run both
#   ./scripts/vps-dedupe-question-images.sh --apply      # quarantine JPG twins
#   ./scripts/vps-dedupe-question-images.sh --apply --delete
#   ./scripts/vps-dedupe-question-images.sh --volume-only
#   ./scripts/vps-dedupe-question-images.sh --staging-only
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

MODE="dry-run"
HARD_DELETE=0
DO_STAGING=1
DO_VOLUME=1
VOLUME_NAME="papermantra_question_images"
STAGING_DIR="${ROOT_DIR}/images"
REPORT_DIR="${ROOT_DIR}/Image_Dedupe_Reports"
PY="${ROOT_DIR}/scripts/dedupe_question_images.py"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) MODE="dry-run" ;;
    --apply) MODE="apply" ;;
    --delete) HARD_DELETE=1 ;;
    --volume-only) DO_STAGING=0; DO_VOLUME=1 ;;
    --staging-only) DO_STAGING=1; DO_VOLUME=0 ;;
    -h|--help)
      sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "ERROR: unknown argument: $1"; exit 1 ;;
  esac
  shift
done

if [[ ! -f "${PY}" ]]; then
  echo "ERROR: missing ${PY}"
  exit 1
fi

mkdir -p "${REPORT_DIR}"
STAMP="$(date +%Y%m%d_%H%M%S)"
ARGS=()
[[ "${MODE}" == "apply" ]] && ARGS+=(--apply) || ARGS+=(--dry-run)
[[ "${HARD_DELETE}" -eq 1 ]] && ARGS+=(--delete)

echo "============================================================"
echo " VPS image dedupe (PNG preferred)"
echo " mode=${MODE}  delete=${HARD_DELETE}"
echo " staging=${STAGING_DIR}"
echo " volume=${VOLUME_NAME}  (= /app/images in api + pdf)"
echo "============================================================"

if [[ "${DO_STAGING}" -eq 1 ]]; then
  echo
  echo ">> [1/2] Staging folder"
  if [[ ! -d "${STAGING_DIR}" ]]; then
    echo "WARN: staging missing, skipping"
  else
    python3 "${PY}" \
      --dir "${STAGING_DIR}" \
      "${ARGS[@]}" \
      --label "vps_staging" \
      --report "${REPORT_DIR}/vps_staging_${MODE}_${STAMP}.json"
  fi
fi

if [[ "${DO_VOLUME}" -eq 1 ]]; then
  echo
  echo ">> [2/2] Shared Docker volume (api + pdf)"
  if ! docker volume inspect "${VOLUME_NAME}" >/dev/null 2>&1; then
    echo "ERROR: volume not found: ${VOLUME_NAME}"
    exit 1
  fi
  docker run --rm \
    -v "${VOLUME_NAME}:/data" \
    -v "${PY}:/dedupe.py:ro" \
    -v "${REPORT_DIR}:/reports" \
    python:3.12-alpine \
    python /dedupe.py \
      --dir /data \
      "${ARGS[@]}" \
      --label "vps_volume_api_pdf" \
      --report "/reports/vps_volume_${MODE}_${STAMP}.json"

  if [[ "${MODE}" == "apply" ]]; then
    docker run --rm -v "${VOLUME_NAME}:/data" alpine:3.20 \
      sh -c 'chmod -R a+rwX /data'
  fi
fi

echo
echo ">> Verify remaining PNG+JPG pairs (active files only)"
python3 - <<PY
from pathlib import Path
from collections import defaultdict

def count_pairs(root: Path) -> tuple[int, int]:
    by = defaultdict(set)
    files = 0
    for p in root.rglob("*"):
        if not p.is_file():
            continue
        if any(part.startswith(".dedupe_quarantine_") for part in p.parts):
            continue
        files += 1
        ext = p.suffix.lower()
        if ext in {".png", ".jpg", ".jpeg"}:
            by[p.stem.lower()].add(ext)
    pairs = sum(1 for v in by.values() if ".png" in v and ({".jpg", ".jpeg"} & v))
    return files, pairs

if ${DO_STAGING}:
    files, pairs = count_pairs(Path("${STAGING_DIR}"))
    print(f"staging: active_files={files} remaining_png_jpg_pairs={pairs}")
PY

if [[ "${DO_VOLUME}" -eq 1 ]]; then
  docker run --rm -v "${VOLUME_NAME}:/data" python:3.12-alpine python - <<'PY'
from pathlib import Path
from collections import defaultdict
root = Path("/data")
by = defaultdict(set)
files = 0
for p in root.rglob("*"):
    if not p.is_file():
        continue
    if any(part.startswith(".dedupe_quarantine_") for part in p.parts):
        continue
    files += 1
    ext = p.suffix.lower()
    if ext in {".png", ".jpg", ".jpeg"}:
        by[p.stem.lower()].add(ext)
pairs = sum(1 for v in by.values() if ".png" in v and ({".jpg", ".jpeg"} & v))
print(f"shared_volume(api+pdf): active_files={files} remaining_png_jpg_pairs={pairs}")
PY

  api_count="$(docker compose exec -T api sh -c 'find /app/images -type f ! -path "*/.dedupe_quarantine_*/*" 2>/dev/null | wc -l' | tr -d ' \r' || echo '?')"
  pdf_count="$(docker compose exec -T pdf sh -c 'find /app/images -type f ! -path "*/.dedupe_quarantine_*/*" 2>/dev/null | wc -l' | tr -d ' \r' || echo '?')"
  echo "api /app/images active=${api_count}"
  echo "pdf /app/images active=${pdf_count}"
  echo "(api and pdf must match — same volume)"
fi

echo
echo ">> Done. Reports in ${REPORT_DIR}"
