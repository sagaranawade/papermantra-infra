#!/usr/bin/env bash
# =============================================================================
# Pull latest papermantra-infra main and deploy when HEAD changed.
#
# Used by systemd timer on the VPS so deploys succeed even when GitHub Actions
# cannot SSH in (provider firewall / transient timeouts on port 22).
#
# Usage:
#   ./scripts/pull-and-deploy-if-changed.sh
#   DEPLOY_SERVICES=portal,api ./scripts/pull-and-deploy-if-changed.sh
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

LOCK_FILE=".pull-deploy.lock"
if [[ -f "${LOCK_FILE}" ]]; then
  echo ">> pull-deploy skipped: ${LOCK_FILE} exists (deploy already running)"
  exit 0
fi

touch "${LOCK_FILE}"
trap 'rm -f "${LOCK_FILE}"' EXIT

git fetch origin main

LOCAL="$(git rev-parse HEAD)"
REMOTE="$(git rev-parse origin/main)"

if [[ "${LOCAL}" == "${REMOTE}" ]]; then
  echo ">> pull-deploy: already at ${LOCAL:0:7} (no changes)"
  exit 0
fi

echo ">> pull-deploy: ${LOCAL:0:7} -> ${REMOTE:0:7}"
git reset --hard origin/main

if [[ ! -f .env ]]; then
  echo "ERROR: .env missing after git reset"
  exit 1
fi

chmod +x scripts/*.sh certbot/*.sh 2>/dev/null || true

if [[ -f .deploy-lock ]]; then
  echo ">> pull-deploy skipped: .deploy-lock exists"
  exit 0
fi

export DEPLOY_SERVICES="${DEPLOY_SERVICES:-portal,website,api,pdf}"
./scripts/deploy.sh --rollback-on-failure

echo ">> pull-deploy complete."
