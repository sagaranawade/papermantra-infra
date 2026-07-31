#!/usr/bin/env bash
# =============================================================================
# Install pull-deploy on the VPS (every 2 minutes via user crontab).
#
# Does NOT require sudo. When GitHub Actions cannot SSH (port 22 timeout),
# the VPS still pulls main and runs deploy.sh automatically.
#
# Run once on the VPS as deploy:
#   cd /opt/papermantra-infra
#   ./scripts/setup-pull-deploy.sh
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_PATH="${ROOT_DIR}"
SCRIPT="${DEPLOY_PATH}/scripts/pull-and-deploy-if-changed.sh"
LOG_FILE="${DEPLOY_PATH}/.pull-deploy.log"

if [[ ! -f "${SCRIPT}" ]]; then
  echo "ERROR: ${SCRIPT} not found"
  exit 1
fi

chmod +x "${SCRIPT}"

# Source optional .ghcr.env (GHCR_PAT=...) so private image pulls work without SSH.
CRON_LINE="*/2 * * * * set -a; [ -f ${DEPLOY_PATH}/.ghcr.env ] && . ${DEPLOY_PATH}/.ghcr.env; set +a; ${SCRIPT} >> ${LOG_FILE} 2>&1"

if crontab -l 2>/dev/null | grep -Fq "${SCRIPT}"; then
  # Refresh the line so GHCR env sourcing is present.
  (crontab -l 2>/dev/null | grep -Fv "${SCRIPT}" || true; echo "${CRON_LINE}") | crontab -
  echo ">> pull-deploy crontab refreshed"
else
  (crontab -l 2>/dev/null | grep -Fv "${SCRIPT}" || true; echo "${CRON_LINE}") | crontab -
  echo ">> Installed crontab (every 2 minutes):"
fi
crontab -l | grep "${SCRIPT}" || true

echo ""
echo ">> Log file: ${LOG_FILE}"
echo ">> Manual run: ${SCRIPT}"
echo ">> Optional: echo 'GHCR_PAT=ghp_xxx' > ${DEPLOY_PATH}/.ghcr.env && chmod 600 ${DEPLOY_PATH}/.ghcr.env"
echo ">> Recommended permanent fix: RUNNER_TOKEN=... ./scripts/install-github-runner.sh"
