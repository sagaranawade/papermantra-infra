#!/usr/bin/env bash
# Manual certificate renewal (also runs automatically via the certbot service).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

docker compose --profile certbot run --rm --entrypoint "\
  certbot renew --webroot -w /var/www/certbot" certbot

docker compose exec nginx nginx -s reload
echo "Certificates renewed and nginx reloaded."
