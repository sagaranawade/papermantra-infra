#!/usr/bin/env bash
# =============================================================================
# One-time migration: merge legacy per-service image volumes into the shared
# papermantra_question_images volume used by both api and pdf.
#
# Safe to re-run (skips if target already has files and source is empty).
#
# Usage:
#   ./scripts/migrate-image-volumes.sh
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

TARGET_VOL="papermantra_question_images"
LEGACY_VOLUMES=(
  "papermantra_api_question_images"
  "papermantra_pdf_images"
)

echo ">> Ensuring shared volume ${TARGET_VOL} exists..."
docker volume create "${TARGET_VOL}" >/dev/null

for legacy in "${LEGACY_VOLUMES[@]}"; do
  if ! docker volume inspect "${legacy}" >/dev/null 2>&1; then
    echo "   skip ${legacy} (not found)"
    continue
  fi
  echo ">> Merging ${legacy} → ${TARGET_VOL}..."
  docker run --rm \
    -v "${legacy}:/from:ro" \
    -v "${TARGET_VOL}:/to" \
    alpine:3.20 \
    sh -c 'if [ -n "$(ls -A /from 2>/dev/null)" ]; then cp -an /from/. /to/; fi'
done

echo ">> Fixing permissions on shared images volume (api=100, pdf=999)..."
docker run --rm \
  -v "${TARGET_VOL}:/data" \
  alpine:3.20 \
  sh -c 'chmod -R a+rwX /data'

echo ">> Done. Redeploy with: ./scripts/deploy.sh"
