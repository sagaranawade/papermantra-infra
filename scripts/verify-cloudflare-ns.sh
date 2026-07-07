#!/usr/bin/env bash
# Verify both domains use Cloudflare nameservers (post-migration).
# Usage: ./scripts/verify-cloudflare-ns.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  source .env
fi

DOMAINS=(
  "${DOMAIN_PAPERMANTRA:-papermantra.com}"
  "${DOMAIN_NEELMIND:-neelmind.com}"
)

FAIL=0

check_ns() {
  local domain="$1"
  local ns_list
  ns_list="$(dig +short "${domain}" NS @1.1.1.1 | sort)"

  if [[ -z "${ns_list}" ]]; then
    echo "FAIL ${domain} — no NS records found"
    FAIL=1
    return
  fi

  local has_cloudflare=0
  local has_parking=0
  while IFS= read -r ns; do
    [[ -z "${ns}" ]] && continue
    if [[ "${ns}" == *cloudflare.com* ]]; then
      has_cloudflare=1
    fi
    if [[ "${ns}" == *dns-parking.com* ]]; then
      has_parking=1
    fi
  done <<< "${ns_list}"

  if [[ "${has_cloudflare}" -eq 1 && "${has_parking}" -eq 0 ]]; then
    echo "OK  ${domain} NS ->"
    echo "${ns_list}" | sed 's/^/      /'
  else
    echo "FAIL ${domain} NS (expected cloudflare.com, not dns-parking.com):"
    echo "${ns_list}" | sed 's/^/      /'
    if [[ "${has_parking}" -eq 1 ]]; then
      echo "     ^ Still on Hostinger parking nameservers. See CLOUDFLARE-MIGRATION.md"
    fi
    FAIL=1
  fi
}

echo "Checking nameservers (resolver 1.1.1.1)"
for domain in "${DOMAINS[@]}"; do
  check_ns "${domain}"
done

exit "${FAIL}"
