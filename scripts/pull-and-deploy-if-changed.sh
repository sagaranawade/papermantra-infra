#!/usr/bin/env bash
# =============================================================================
# Pull latest papermantra-infra main and deploy when:
#   1) git HEAD changed, OR
#   2) running container image tags do not match .env pins
#
# Used by crontab on the VPS so deploys succeed even when GitHub Actions
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
HEAD_CHANGED=0

if [[ "${LOCAL}" != "${REMOTE}" ]]; then
  HEAD_CHANGED=1
  echo ">> pull-deploy: ${LOCAL:0:7} -> ${REMOTE:0:7}"
  git reset --hard origin/main
else
  echo ">> pull-deploy: already at ${LOCAL:0:7}"
fi

if [[ ! -f .env ]]; then
  echo "ERROR: .env missing after git sync"
  exit 1
fi

chmod +x scripts/*.sh certbot/*.sh 2>/dev/null || true

if [[ -f .deploy-lock ]]; then
  echo ">> pull-deploy skipped: .deploy-lock exists"
  exit 0
fi

# Login so docker manifest / pull works for private GHCR packages.
if [[ -n "${GHCR_PAT:-${GHCR_TOKEN:-}}" ]]; then
  echo "${GHCR_PAT:-${GHCR_TOKEN}}" | docker login ghcr.io -u "${GHCR_USER:-sagaranawade}" --password-stdin >/dev/null
elif [[ -f "${HOME}/.docker/config.json" ]]; then
  :
else
  echo "WARN: no GHCR credentials in env; pull may fail for private images"
fi

export DEPLOY_SERVICES="${DEPLOY_SERVICES:-portal,website,api,pdf}"

NEED_DEPLOY="${HEAD_CHANGED}"
if ! DEPLOY_SERVICES="${DEPLOY_SERVICES}" ./scripts/images-match-env.sh >/tmp/pm-image-match.txt 2>&1; then
  echo ">> pull-deploy: running images do not match .env pins — redeploying"
  cat /tmp/pm-image-match.txt || true
  NEED_DEPLOY=1
else
  cat /tmp/pm-image-match.txt || true
fi

if [[ "${NEED_DEPLOY}" -ne 1 ]]; then
  echo ">> pull-deploy: nothing to do"
  # Keep public meta fresh even when no recreate was needed.
  ./scripts/write-deploy-meta.sh || true
  exit 0
fi

# Prefer only the services that are actually wrong / changed.
# - On git HEAD change: use .env IMAGE_* diff when available
# - On tag drift with unchanged HEAD: deploy only mismatched containers
#   (avoids re-pulling website/robofume when only portal is behind)
if [[ "${HEAD_CHANGED}" -eq 1 ]]; then
  DETECTED="$(./scripts/resolve-deploy-services.sh || true)"
  if [[ -n "${DETECTED}" ]]; then
    export DEPLOY_SERVICES="${DETECTED}"
    echo ">> Auto-detected changed services from .env diff: ${DEPLOY_SERVICES}"
  fi
else
  MISMATCHED="$(./scripts/mismatched-services.sh || true)"
  if [[ -n "${MISMATCHED}" ]]; then
    export DEPLOY_SERVICES="${MISMATCHED}"
    echo ">> Redeploying only mismatched services: ${DEPLOY_SERVICES}"
  fi
fi

./scripts/deploy.sh --rollback-on-failure
echo ">> pull-deploy complete."
