#!/usr/bin/env bash
# Create self-signed placeholder certs so nginx can start before Let's Encrypt runs.
# Safe to re-run after a failed certbot attempt (fixes nginx crash loop).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  source .env
fi

domains=(
  "${DOMAIN_PAPERMANTRA:-papermantra.com}"
  "${DOMAIN_NEELMIND:-neelmind.com}"
  "${DOMAIN_API:-api.papermantra.com}"
  "${DOMAIN_PDF:-pdf.papermantra.com}"
)

rsa_key_size=4096
mkdir -p certbot/conf certbot/www

for domain in "${domains[@]}"; do
  path="./certbot/conf/live/${domain}"
  mkdir -p "${path}"
  if [[ -f "${path}/fullchain.pem" && -f "${path}/privkey.pem" ]]; then
    echo ">> ${domain}: certs already present, skipping"
    continue
  fi
  echo ">> ${domain}: creating dummy certificate"
  openssl req -x509 -nodes -newkey "rsa:${rsa_key_size}" -days 1 \
    -keyout "${path}/privkey.pem" \
    -out "${path}/fullchain.pem" \
    -subj "/CN=${domain}" 2>/dev/null
done

echo ">> Done. Start nginx: docker compose up -d nginx"
