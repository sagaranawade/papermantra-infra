#!/usr/bin/env bash
# Issue Let's Encrypt certs for partner hosts only (does not renew papermantra.com).
# DNS must already point at this VPS. Cloudflare proxy must be DNS-only (grey).
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

rsa_key_size=4096
email="${CERTBOT_EMAIL}"
staging_arg=""
if [[ "${STAGING:-0}" != "0" ]]; then
  staging_arg="--staging"
  echo ">> Using Let's Encrypt STAGING"
fi

mkdir -p certbot/conf certbot/www
bash "${SCRIPT_DIR}/create-dummy-certs.sh"
docker compose up -d nginx

issue() {
  local cert_name="$1"
  shift
  echo ">> Requesting ${cert_name} ($*)"
  bash "${SCRIPT_DIR}/cleanup-placeholders.sh" "${cert_name}"
  docker compose --profile certbot run --rm --entrypoint "\
    certbot certonly --webroot -w /var/www/certbot \
      ${staging_arg} \
      $* \
      --cert-name ${cert_name} \
      --email ${email} \
      --rsa-key-size ${rsa_key_size} \
      --agree-tos \
      --no-eff-email" certbot
}

issue "${DOMAIN_EDISHA}" -d "${DOMAIN_EDISHA}"
issue "${DOMAIN_STUDYLAB}" -d "${DOMAIN_STUDYLAB}" -d "${DOMAIN_STUDYLAB_WWW}"

sudo chown -R "$(whoami):$(whoami)" certbot/conf 2>/dev/null || true
docker compose exec nginx nginx -s reload
echo ">> Partner certificates issued."
