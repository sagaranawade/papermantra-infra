#!/usr/bin/env bash
# =============================================================================
# Run production deploy on the VPS (called from GitHub Actions or manually).
#
# Environment (set by CI or caller):
#   DEPLOY_PATH          default /opt/papermantra-infra
#   CI_PIN_TAG           optional image tag to pin
#   CI_PIN_ALL           true|false
#   CI_SOURCE            manual | papermantra | papermantraservices | ...
#   CI_EVENT_NAME        push | workflow_dispatch | repository_dispatch
#   CI_DEPLOY_SERVICE    portal|website|api|pdf|all
#   GHCR_PAT / GHCR_USER optional registry login
#   SKIP_GIT_SYNC        set to 1 when checkout is already at DEPLOY_PATH
# =============================================================================
set -euo pipefail

DEPLOY_PATH="${DEPLOY_PATH:-/opt/papermantra-infra}"
PIN_TAG="${CI_PIN_TAG:-}"
PIN_ALL="${CI_PIN_ALL:-false}"
SOURCE="${CI_SOURCE:-manual}"
EVENT_NAME="${CI_EVENT_NAME:-manual}"
DEPLOY_SERVICE_INPUT="${CI_DEPLOY_SERVICE:-all}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-sagaranawade/papermantra-infra}"

if [[ "${SKIP_GIT_SYNC:-0}" != "1" ]]; then
  if [[ ! -d "${DEPLOY_PATH}" ]]; then
    echo "Cloning infra repo to ${DEPLOY_PATH}..."
    sudo mkdir -p "$(dirname "${DEPLOY_PATH}")"
    sudo git clone "https://github.com/${GITHUB_REPOSITORY}.git" "${DEPLOY_PATH}"
    sudo chown -R "$(whoami):$(whoami)" "${DEPLOY_PATH}"
  fi

  cd "${DEPLOY_PATH}"
  git fetch origin main
  git reset --hard origin/main
else
  cd "${DEPLOY_PATH}"
fi

if [[ ! -f .env ]]; then
  echo "ERROR: ${DEPLOY_PATH}/.env is missing."
  exit 1
fi

chmod +x scripts/*.sh certbot/*.sh 2>/dev/null || true
echo ">> Recording pre-deploy image tags (for rollback)..."
./scripts/record-deploy-snapshot.sh

DEPLOY_SERVICES="portal,website,api,pdf"

if [[ "${SOURCE}" == "manual" && -z "${PIN_TAG}" ]]; then
  if [[ "${EVENT_NAME}" == "push" ]]; then
    DETECTED="$(./scripts/resolve-deploy-services.sh)"
    if [[ -n "${DETECTED}" ]]; then
      DEPLOY_SERVICES="${DETECTED}"
      echo ">> Auto-detected changed services from .env diff: ${DEPLOY_SERVICES}"
    fi
  elif [[ "${DEPLOY_SERVICE_INPUT}" != "all" && -n "${DEPLOY_SERVICE_INPUT}" ]]; then
    DEPLOY_SERVICES="${DEPLOY_SERVICE_INPUT}"
    echo ">> Manual deploy limited to: ${DEPLOY_SERVICES}"
  fi
fi

if [[ -n "${PIN_TAG}" ]]; then
  if [[ "${PIN_ALL}" == "true" ]]; then
    echo "Unified release: pinning all IMAGE_* to ${PIN_TAG}"
    ./scripts/pin-image-tag.sh "${PIN_TAG}" --all
  elif [[ "${SOURCE}" != "manual" ]]; then
    echo "Per-service release: pinning ${SOURCE} to ${PIN_TAG}"
    ./scripts/pin-image-tag.sh "${PIN_TAG}" --source "${SOURCE}"
    case "${SOURCE}" in
      papermantra) DEPLOY_SERVICES="portal" ;;
      robofume) DEPLOY_SERVICES="website" ;;
      papermantraservices) DEPLOY_SERVICES="api" ;;
      pdfgenerator) DEPLOY_SERVICES="pdf" ;;
    esac
  elif [[ "${DEPLOY_SERVICE_INPUT}" != "all" && -n "${DEPLOY_SERVICE_INPUT}" ]]; then
    echo "Manual single-service pin: ${DEPLOY_SERVICE_INPUT} -> ${PIN_TAG}"
    ./scripts/pin-image-tag.sh "${PIN_TAG}" --service "${DEPLOY_SERVICE_INPUT}"
    DEPLOY_SERVICES="${DEPLOY_SERVICE_INPUT}"
  fi
fi

if [[ -n "${GHCR_PAT:-}" ]]; then
  echo "${GHCR_PAT}" | docker login ghcr.io -u "${GHCR_USER:-sagaranawade}" --password-stdin
else
  echo "WARN: GHCR_PAT not set — assuming docker login already configured on VPS"
fi

echo "Deploy triggered by: ${SOURCE} (services: ${DEPLOY_SERVICES})"
export DEPLOY_SERVICES
./scripts/deploy.sh --rollback-on-failure
