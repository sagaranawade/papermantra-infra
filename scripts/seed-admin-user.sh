#!/usr/bin/env bash
# =============================================================================
# Create the first admin login in an empty production MongoDB (one-time).
# Uses the public /api/v1/user/register endpoint.
#
# Usage:
#   ./scripts/seed-admin-user.sh
#   ./scripts/seed-admin-user.sh admin@example.com 'MyPassword'
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

# shellcheck disable=SC1091
source .env

EMAIL="${1:-${AUTH_USERNAME:-admin@papermantra.com}}"
PASSWORD="${2:-${AUTH_PASSWORD:-}}"
API_BASE="${AUTH_BASE_URL:-http://api:9091}"

if [[ -z "${PASSWORD}" ]]; then
  echo "ERROR: Set AUTH_PASSWORD in .env or pass password as second argument."
  exit 1
fi

echo ">> Registering admin user ${EMAIL} via ${API_BASE} ..."
payload=$(printf '{"emailId":"%s","password":"%s"}' "${EMAIL}" "${PASSWORD}")

if curl -fsSk -X POST "${API_BASE}/papermantra/api/v1/user/register" \
  -H "Content-Type: application/json" \
  -d "${payload}"; then
  echo ""
  echo ">> Admin user registered. Try logging in at https://papermantra.com"
else
  echo ""
  echo "WARN: Register failed (user may already exist). Try login or import full DB with sync-data-to-prod.ps1"
  exit 1
fi
