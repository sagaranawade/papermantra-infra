#!/usr/bin/env bash
# Remove self-signed placeholder certs via Docker (root) — fixes "Permission denied" on archive/.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

cert_name="${1:?Usage: cleanup-placeholders.sh <cert-name>}"

docker compose --profile certbot run --rm --entrypoint \
  "sh -c 'for n in ${cert_name} ${cert_name}-0001 ${cert_name}-0002; do
    if [ -f /etc/letsencrypt/renewal/\${n}.conf ]; then
      echo keep real cert: \${n}
    else
      echo remove placeholder: \${n}
      rm -rf /etc/letsencrypt/live/\${n} /etc/letsencrypt/archive/\${n}
      rm -f /etc/letsencrypt/renewal/\${n}.conf
    fi
  done'" certbot

# Let deploy user manage certs after certbot runs
if [[ -d certbot/conf ]]; then
  sudo chown -R "$(whoami):$(whoami)" certbot/conf 2>/dev/null || true
fi
