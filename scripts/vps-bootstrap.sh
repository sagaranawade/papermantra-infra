#!/usr/bin/env bash
# Run once on the VPS after cloning papermantra-infra to /opt/papermantra-infra
#
# Usage (as deploy):
#   cd /opt/papermantra-infra
#   ./scripts/vps-bootstrap.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

echo ">> PaperMantra VPS bootstrap"
echo "   Directory: ${ROOT_DIR}"

if [[ "$(id -un)" == "root" ]]; then
  echo "WARN: Running as root. Prefer user 'deploy' for day-to-day ops."
fi

echo ">> Making scripts executable..."
chmod +x scripts/*.sh certbot/*.sh

if [[ ! -f .env ]]; then
  if [[ -f .env.production.template ]]; then
    echo ">> Creating .env from .env.production.template..."
    cp .env.production.template .env
    echo "   EDIT REQUIRED: nano .env"
    echo "   Set MONGO_ROOT_PASSWORD, REDIS_PASSWORD (and GRAFANA if using monitoring)"
  else
    echo ">> Creating .env from .env.example..."
    cp .env.example .env
    echo "   EDIT REQUIRED: nano .env"
  fi
else
  echo ">> .env already exists — not overwriting."
fi

if groups | grep -q docker || id -Gn | grep -q docker; then
  echo ">> Docker group: OK"
else
  echo "WARN: Current user is not in 'docker' group."
  echo "      Run: sudo usermod -aG docker $(whoami) && log out/in"
fi

if docker compose version >/dev/null 2>&1; then
  echo ">> docker compose: $(docker compose version --short 2>/dev/null || docker compose version)"
else
  echo "ERROR: docker compose not found."
  exit 1
fi

echo ""
echo ">> Next steps:"
echo "   1. nano .env                          # set CHANGE_ME passwords"
echo "   2. ./scripts/validate-env.sh"
echo "   3. echo PAT | docker login ghcr.io -u sagaranawade --password-stdin"
echo "   4. ./certbot/init-letsencrypt.sh"
echo "   5. docker compose --profile certbot up -d certbot"
echo "   6. Tag v1.0.0 in all 4 app repos (GitHub Actions → GHCR)"
echo "   7. ./scripts/deploy.sh"
echo ""
echo "See VPS-SETUP.md for full instructions."
