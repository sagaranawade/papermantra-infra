#!/usr/bin/env bash
# =============================================================================
# Install a systemd timer on the VPS that pulls papermantra-infra every 2
# minutes and runs deploy.sh when main changed.
#
# Run once on the VPS as the deploy user (requires passwordless sudo for
# systemctl enable/start):
#   cd /opt/papermantra-infra
#   ./scripts/setup-pull-deploy.sh
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_USER="$(id -un)"
DEPLOY_PATH="${ROOT_DIR}"
SCRIPT="${DEPLOY_PATH}/scripts/pull-and-deploy-if-changed.sh"

if [[ ! -f "${SCRIPT}" ]]; then
  echo "ERROR: ${SCRIPT} not found"
  exit 1
fi

chmod +x "${SCRIPT}"

SERVICE="/etc/systemd/system/papermantra-pull-deploy.service"
TIMER="/etc/systemd/system/papermantra-pull-deploy.timer"

sudo tee "${SERVICE}" >/dev/null <<EOF
[Unit]
Description=PaperMantra pull-and-deploy when papermantra-infra main changes
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
User=${DEPLOY_USER}
WorkingDirectory=${DEPLOY_PATH}
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=${SCRIPT}
Nice=10
EOF

sudo tee "${TIMER}" >/dev/null <<EOF
[Unit]
Description=Run PaperMantra pull-deploy every 2 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=2min
AccuracySec=30s
Persistent=true

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now papermantra-pull-deploy.timer

echo ">> Installed papermantra-pull-deploy.timer"
systemctl list-timers papermantra-pull-deploy.timer --no-pager || true
echo ""
echo ">> Manual run: ${SCRIPT}"
