#!/usr/bin/env bash
# =============================================================================
# Install a GitHub Actions self-hosted runner on this VPS (recommended fix
# for "dial tcp :22: connection timed out" from GitHub-hosted runners).
#
# With a self-hosted runner, deploy jobs run ON the VPS — no inbound SSH from
# GitHub required.
#
# One-time setup:
#   1. GitHub → papermantra-infra → Settings → Actions → Runners → New runner
#   2. Copy the registration token (expires in 1 hour)
#   3. On VPS:
#        cd /opt/papermantra-infra
#        RUNNER_TOKEN=<token> ./scripts/install-github-runner.sh
#   4. In GitHub repo Settings → Variables, set DEPLOY_RUNNER=self-hosted
#
# Usage:
#   RUNNER_TOKEN=XXXX ./scripts/install-github-runner.sh
#   RUNNER_TOKEN=XXXX RUNNER_LABELS=papermantra-prod,production ./scripts/install-github-runner.sh
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER_USER="$(id -un)"
RUNNER_HOME="${RUNNER_HOME:-${HOME}/actions-runner}"
RUNNER_VERSION="${RUNNER_VERSION:-2.321.0}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,papermantra-prod,production}"
REPO="${RUNNER_REPO:-sagaranawade/papermantra-infra}"

if [[ -z "${RUNNER_TOKEN:-}" ]]; then
  echo "ERROR: Set RUNNER_TOKEN from GitHub → Settings → Actions → Runners → New runner"
  exit 1
fi

ARCH="$(uname -m)"
case "${ARCH}" in
  x86_64) RUNNER_ARCH=x64 ;;
  aarch64|arm64) RUNNER_ARCH=arm64 ;;
  *)
    echo "ERROR: unsupported architecture ${ARCH}"
    exit 1
    ;;
esac

mkdir -p "${RUNNER_HOME}"
cd "${RUNNER_HOME}"

if [[ ! -f ./config.sh ]]; then
  echo ">> Downloading actions-runner ${RUNNER_VERSION} (${RUNNER_ARCH})..."
  curl -fsSL -o actions-runner.tar.gz \
    "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"
  tar xzf actions-runner.tar.gz
  rm -f actions-runner.tar.gz
fi

if [[ -f ./.runner ]]; then
  echo ">> Runner already configured in ${RUNNER_HOME}"
  sudo ./svc.sh status 2>/dev/null || true
  exit 0
fi

./config.sh \
  --url "https://github.com/${REPO}" \
  --token "${RUNNER_TOKEN}" \
  --name "$(hostname)-prod" \
  --labels "${RUNNER_LABELS}" \
  --work "_work" \
  --unattended \
  --replace

echo ">> Installing systemd service for runner..."
sudo ./svc.sh install "${RUNNER_USER}"
sudo ./svc.sh start
sudo ./svc.sh status

echo ""
echo ">> Runner installed. Next:"
echo "   1. GitHub → papermantra-infra → Settings → Variables → DEPLOY_RUNNER = self-hosted"
echo "   2. Re-run a failed deploy workflow (it will use this runner, no SSH)"
