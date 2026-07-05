#!/usr/bin/env bash
# =============================================================================
# Bootstrap Let's Encrypt certificates for all production domains.
#
# Prerequisites:
#   1. DNS A records for all domains must point to this VPS.
#   2. Ports 80/443 open in the firewall.
#   3. .env file populated (see .env.example).
#
# Usage:
#   chmod +x certbot/init-letsencrypt.sh
#   ./certbot/init-letsencrypt.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT_DIR}"

if [[ ! -f .env ]]; then
  echo "ERROR: .env not found. Copy .env.example to .env first."
  exit 1
fi

# shellcheck disable=SC1091
source .env

domains=(
  "${DOMAIN_PAPERMANTRA}"
  "${DOMAIN_NEELMIND}"
  "${DOMAIN_API}"
  "${DOMAIN_PDF}"
)

rsa_key_size=4096
email="${CERTBOT_EMAIL}"
staging="${STAGING:-0}"

if [[ "${staging}" != "0" ]]; then
  staging_arg="--staging"
  echo ">> Using Let's Encrypt STAGING (no browser-trusted certs)"
else
  staging_arg=""
fi

mkdir -p certbot/conf certbot/www

echo ">> Creating dummy certificates so nginx can start..."
for domain in "${domains[@]}"; do
  path="./certbot/conf/live/${domain}"
  mkdir -p "${path}"
  if [[ ! -f "${path}/fullchain.pem" ]]; then
    openssl req -x509 -nodes -newkey rsa:${rsa_key_size} -days 1 \
      -keyout "${path}/privkey.pem" \
      -out "${path}/fullchain.pem" \
      -subj "/CN=${domain}" 2>/dev/null
  fi
done

echo ">> Starting nginx with dummy certs..."
docker compose up -d nginx

echo ">> Deleting dummy certificates..."
for domain in "${domains[@]}"; do
  docker compose --profile certbot run --rm --entrypoint "\
    rm -Rf /etc/letsencrypt/live/${domain} && \
    rm -Rf /etc/letsencrypt/archive/${domain} && \
    rm -f /etc/letsencrypt/renewal/${domain}.conf" certbot
done

echo ">> Requesting real certificates from Let's Encrypt..."
for domain in "${domains[@]}"; do
  extra_args=""
  if [[ "${domain}" == "${DOMAIN_PAPERMANTRA}" ]]; then
    extra_args="-d ${DOMAIN_PAPERMANTRA} -d ${DOMAIN_PAPERMANTRA_WWW}"
  elif [[ "${domain}" == "${DOMAIN_NEELMIND}" ]]; then
    extra_args="-d ${DOMAIN_NEELMIND} -d ${DOMAIN_NEELMIND_WWW}"
  else
    extra_args="-d ${domain}"
  fi

  docker compose --profile certbot run --rm --entrypoint "\
    certbot certonly --webroot -w /var/www/certbot \
      ${staging_arg} \
      ${extra_args} \
      --email ${email} \
      --rsa-key-size ${rsa_key_size} \
      --agree-tos \
      --no-eff-email \
      --force-renewal" certbot
done

echo ">> Reloading nginx with real certificates..."
docker compose exec nginx nginx -s reload

echo ">> Done. Start the certbot renewal sidecar:"
echo "   docker compose --profile certbot up -d certbot"
