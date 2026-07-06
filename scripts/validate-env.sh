#!/usr/bin/env bash
# Validate /opt/papermantra-infra/.env before SSL or deploy.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "ERROR: ${ENV_FILE} not found."
  echo "Run: git pull origin main"
  exit 1
fi

# shellcheck disable=SC1090
set -a
source "${ENV_FILE}"
set +a

errors=0
warn=0

check_required() {
  local name="$1"
  local value="${!name:-}"
  if [[ -z "${value}" ]]; then
    echo "  FAIL  ${name} is empty"
    errors=$((errors + 1))
    return
  fi
  if [[ "${value}" == CHANGE_ME* ]]; then
    echo "  FAIL  ${name} still has placeholder: ${value}"
    errors=$((errors + 1))
    return
  fi
  echo "  OK    ${name}"
}

check_optional_warn() {
  local name="$1"
  local value="${!name:-}"
  if [[ -z "${value}" ]]; then
    echo "  WARN  ${name} is empty (optional but recommended)"
    warn=$((warn + 1))
  else
    echo "  OK    ${name}"
  fi
}

echo ">> Checking required secrets..."
for var in \
  MONGO_ROOT_PASSWORD REDIS_PASSWORD JWT_SECRET \
  AUTH_USERNAME AUTH_PASSWORD \
  MONGODB_URI PDF_MONGODB_URI \
  IMAGE_PAPERMANTRA IMAGE_ROBOFUME IMAGE_SERVICES IMAGE_PDF \
  CERTBOT_EMAIL GOOGLE_GEN_REDIRECT_URI GOOGLE_GEN_JS_ORIGINS; do
  check_required "${var}"
done

echo ""
echo ">> Checking URLs..."
for var in AUTH_BASE_URL QP_BASE_URL PDF_BASE_URL GOOGLE_GEN_REDIRECT_URI; do
  check_required "${var}"
done

if [[ "${JWT_SECRET}" == "changeit" ]]; then
  echo "  WARN  JWT_SECRET is still 'changeit' (matches local; rotate later for hardening)"
  warn=$((warn + 1))
fi

if [[ "${MONGODB_URI}" == *'CHANGE_ME'* ]] || [[ "${PDF_MONGODB_URI}" == *'CHANGE_ME'* ]]; then
  echo "  FAIL  MONGODB_URI or PDF_MONGODB_URI still contains CHANGE_ME — set MONGO_ROOT_PASSWORD first"
  errors=$((errors + 1))
fi

echo ""
echo ">> Optional..."
check_optional_warn GRAFANA_ADMIN_PASSWORD

echo ""
if [[ "${errors}" -gt 0 ]]; then
  echo "RESULT: ${errors} error(s), ${warn} warning(s) — fix .env before continuing."
  exit 1
fi

echo "RESULT: .env looks ready (${warn} warning(s))."
exit 0
