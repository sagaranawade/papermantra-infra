#!/usr/bin/env bash
# =============================================================================
# Append a complete IMAGE_* snapshot to .deploy-history (used for rollback).
# Always records all four service image lines, even when only one service deploys.
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

HISTORY_FILE=".deploy-history"
TIMESTAMP="$(date -u +"%Y%m%dT%H%M%SZ")"

if [[ ! -f .env ]]; then
  echo "ERROR: .env not found."
  exit 1
fi

{
  echo "# ${TIMESTAMP}"
  for key in IMAGE_PAPERMANTRA IMAGE_ROBOFUME IMAGE_SERVICES IMAGE_PDF; do
    if grep -q "^${key}=" .env; then
      grep "^${key}=" .env
    else
      echo "${key}="
    fi
  done
} >> "${HISTORY_FILE}"

echo ">> Recorded deploy snapshot at ${TIMESTAMP}"
