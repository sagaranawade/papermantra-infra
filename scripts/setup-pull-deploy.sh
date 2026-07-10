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

CRON_LINE="*/2 * * * * ${SCRIPT} >> ${LOG_FILE} 2>&1"

if crontab -l 2>/dev/null | grep -Fq "${SCRIPT}"; then
  echo ">> pull-deploy crontab already installed"
else
  (crontab -l 2>/dev/null | grep -Fv "${SCRIPT}" || true; echo "${CRON_LINE}") | crontab -
  echo ">> Installed crontab (every 2 minutes):"
  crontab -l | grep "${SCRIPT}"
fi

echo ""
echo ">> Log file: ${LOG_FILE}"
echo ">> Manual run: ${SCRIPT}"
