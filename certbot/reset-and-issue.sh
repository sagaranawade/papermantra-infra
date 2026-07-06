#!/usr/bin/env bash
# Nuclear reset: wipe all LE state, recreate nginx placeholders, re-issue all certs.
# Use when certs landed as *-0001 or permissions are broken.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

echo ">> Wiping all certificate data (live/archive/renewal)..."
docker compose --profile certbot run --rm --entrypoint \
  "rm -rf /etc/letsencrypt/live /etc/letsencrypt/archive /etc/letsencrypt/renewal" certbot

mkdir -p certbot/conf/live certbot/conf/archive certbot/conf/renewal
sudo chown -R "$(whoami):$(whoami)" certbot/conf 2>/dev/null || true

echo ">> Recreating nginx placeholders..."
bash "${ROOT_DIR}/certbot/create-dummy-certs.sh"

echo ">> Starting nginx..."
docker compose up -d nginx

echo ">> Issuing fresh Let's Encrypt certificates..."
bash "${ROOT_DIR}/certbot/init-letsencrypt.sh"
