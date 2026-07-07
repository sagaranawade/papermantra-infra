#!/usr/bin/env bash
# Verify public DNS for papermantra domains points at the VPS.
# Usage: ./scripts/verify-dns.sh [expected_ip]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  source .env
fi

EXPECTED_IP="${1:-187.127.189.114}"
FAIL=0

resolve_a() {
  local host="$1"
  local ip
  ip="$(dig +short "${host}" A @1.1.1.1 | awk '/^[0-9]+\./ { line=$0 } END { print line }')"
  printf '%s' "${ip}"
}

check_host() {
  local host="$1"
  local ip
  ip="$(resolve_a "${host}")"
  if [[ "${ip}" == "${EXPECTED_IP}" ]]; then
    echo "OK  ${host} -> ${ip}"
  else
    echo "FAIL ${host} -> ${ip:-<no A record>} (expected ${EXPECTED_IP})"
    FAIL=1
  fi
}

echo "Checking DNS (resolver 1.1.1.1, expected A = ${EXPECTED_IP})"
check_host "${DOMAIN_PAPERMANTRA:-papermantra.com}"
check_host "${DOMAIN_PAPERMANTRA_WWW:-www.papermantra.com}"
check_host "${DOMAIN_API:-api.papermantra.com}"
check_host "${DOMAIN_PDF:-pdf.papermantra.com}"
check_host "${DOMAIN_NEELMIND:-neelmind.com}"
check_host "${DOMAIN_NEELMIND_WWW:-www.neelmind.com}"

exit "${FAIL}"
