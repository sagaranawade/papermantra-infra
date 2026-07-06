#!/usr/bin/env bash
# =============================================================================
# Restore the previous IMAGE_* tags from .deploy-history and redeploy.
#
# Usage:
#   ./scripts/rollback.sh
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

HISTORY_FILE=".deploy-history"

if [[ ! -f "${HISTORY_FILE}" ]]; then
  echo "ERROR: No deployment history found (${HISTORY_FILE})."
  exit 1
fi

# Find the second-to-last IMAGE block (previous deployment)
mapfile -t blocks < <(awk '/^# / { if (block) print block; block="" } { block = block $0 ORS } END { if (block) print block }' "${HISTORY_FILE}")

if [[ "${#blocks[@]}" -lt 2 ]]; then
  echo "ERROR: Not enough history entries to roll back."
  exit 1
fi

PREVIOUS="${blocks[$(( ${#blocks[@]} - 2 ))]}"
echo ">> Rolling back to previous image tags:"
echo "${PREVIOUS}"

while IFS= read -r line; do
  [[ "${line}" =~ ^IMAGE_ ]] || continue
  key="${line%%=*}"
  val="${line#*=}"
  if grep -q "^${key}=" .env; then
    sed -i.bak "s|^${key}=.*|${key}=${val}|" .env
  else
    echo "${line}" >> .env
  fi
done <<< "${PREVIOUS}"

rm -f .env.bak

echo ">> Pulling rolled-back images..."
docker compose pull

echo ">> Restarting stack..."
docker compose up -d --remove-orphans

echo ">> Rollback complete."
