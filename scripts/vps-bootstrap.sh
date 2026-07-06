#!/usr/bin/env bash
# Run once on the VPS after cloning papermantra-infra.
# Production config lives in .env on main — no copy/edit step on the server.
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
  echo "ERROR: .env not found. Run: git pull origin main"
  exit 1
fi

echo ">> Using .env from repository (main branch)."

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

./scripts/validate-env.sh

echo ""
echo ">> Next steps:"
echo "   1. ./scripts/ghcr-login.sh"
echo "   2. ./certbot/init-letsencrypt.sh"
echo "   3. docker compose --profile certbot up -d certbot"
echo "   4. Tag v1.0.0 in all 4 app repos (GitHub Actions → GHCR)"
echo "   5. ./scripts/deploy.sh"
echo ""
echo "To change config later: edit .env in the repo, push to main, git pull on VPS."
