#!/usr/bin/env bash
# =============================================================================
# Update IMAGE_* tag(s) in .env.
#
# Per-service (default when an app repo triggers deploy):
#   ./scripts/pin-image-tag.sh v1.0.7 --source pdfgenerator
#
# Unified release (all services same tag):
#   ./scripts/pin-image-tag.sh v1.0.6 --all
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

if [[ ! -f .env ]]; then
  echo "ERROR: .env not found."
  exit 1
fi

TAG="${1:-}"
MODE="${2:-}"
ARG="${3:-}"

if [[ -z "${TAG}" ]]; then
  echo "Usage: $0 <tag> --all | --source <repo-name> | --service <portal|website|api|pdf>"
  exit 1
fi

if [[ "${TAG}" != v* ]]; then
  TAG="v${TAG}"
fi

pin_var() {
  local var="$1"
  if ! grep -q "^${var}=" .env; then
    echo "ERROR: ${var} not found in .env"
    exit 1
  fi
  sed -i -E "s|^(${var}=.*):[^[:space:]]+|\1:${TAG}|" .env
  echo ">> ${var} -> :${TAG}"
}

source_to_var() {
  case "$1" in
    papermantra) echo "IMAGE_PAPERMANTRA" ;;
    robofume) echo "IMAGE_ROBOFUME" ;;
    papermantraservices) echo "IMAGE_SERVICES" ;;
    pdfgenerator) echo "IMAGE_PDF" ;;
    *)
      echo "ERROR: unknown source '$1' (expected papermantra|robofume|papermantraservices|pdfgenerator)" >&2
      exit 1
      ;;
  esac
}

service_to_var() {
  case "$1" in
    portal) echo "IMAGE_PAPERMANTRA" ;;
    website) echo "IMAGE_ROBOFUME" ;;
    api) echo "IMAGE_SERVICES" ;;
    pdf) echo "IMAGE_PDF" ;;
    *)
      echo "ERROR: unknown service '$1' (expected portal|website|api|pdf)" >&2
      exit 1
      ;;
  esac
}

case "${MODE}" in
  --all)
    for var in IMAGE_PAPERMANTRA IMAGE_ROBOFUME IMAGE_SERVICES IMAGE_PDF; do
      pin_var "${var}"
    done
    ;;
  --source)
    if [[ -z "${ARG}" ]]; then
      echo "ERROR: --source requires repo name"
      exit 1
    fi
    pin_var "$(source_to_var "${ARG}")"
    ;;
  --service)
    if [[ -z "${ARG}" ]]; then
      echo "ERROR: --service requires portal|website|api|pdf"
      exit 1
    fi
    pin_var "$(service_to_var "${ARG}")"
    ;;
  *)
    echo "ERROR: second argument must be --all, --source, or --service"
    exit 1
    ;;
esac
