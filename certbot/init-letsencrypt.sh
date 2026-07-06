#!/usr/bin/env bash
# =============================================================================
# Bootstrap Let's Encrypt certificates for all production domains.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT_DIR}"

if [[ ! -f .env ]]; then
  echo "ERROR: .env not found."
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
  echo ">> Using Let's Encrypt STAGING"
else
  staging_arg=""
fi

mkdir -p certbot/conf certbot/www

echo ">> Ensuring dummy certificates exist (nginx :443)..."
bash "${SCRIPT_DIR}/create-dummy-certs.sh"

echo ">> Starting nginx..."
docker compose up -d nginx

echo ">> Requesting real certificates from Let's Encrypt..."
for domain in "${domains[@]}"; do
  echo ">> Preparing ${domain}..."
  bash "${SCRIPT_DIR}/cleanup-placeholders.sh" "${domain}"

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
      --cert-name ${domain} \
      --email ${email} \
      --rsa-key-size ${rsa_key_size} \
      --agree-tos \
      --no-eff-email \
      --force-renewal" certbot

  sudo chown -R "$(whoami):$(whoami)" certbot/conf 2>/dev/null || true
done

echo ">> Reloading nginx with real certificates..."
docker compose exec nginx nginx -s reload

echo ">> Done. Start renewal sidecar:"
echo "   docker compose --profile certbot up -d certbot"
