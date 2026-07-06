#!/usr/bin/env bash
# Log in to GitHub Container Registry on the VPS.
#
# Usage:
#   GHCR_TOKEN=ghp_xxxx ./scripts/ghcr-login.sh
#   # or paste when prompted:
#   ./scripts/ghcr-login.sh
set -euo pipefail

GHCR_USER="${GHCR_USER:-sagaranawade}"

if [[ -z "${GHCR_TOKEN:-}" ]]; then
  echo -n "Paste GitHub PAT (read:packages): "
  read -rs GHCR_TOKEN
  echo ""
fi

if [[ -z "${GHCR_TOKEN}" ]]; then
  echo "ERROR: GHCR_TOKEN is empty."
  exit 1
fi

echo "${GHCR_TOKEN}" | docker login ghcr.io -u "${GHCR_USER}" --password-stdin
echo ">> Logged in to ghcr.io as ${GHCR_USER}"
