#!/usr/bin/env bash
# =============================================================================
# Public smoke check: https://papermantra.com/deploy-meta.json must report
# running tags that match the expected pins for the given services.
#
# Usage:
#   EXPECTED_PORTAL=v1.0.77 SERVICES=portal ./scripts/verify-public-deploy-meta.sh
#   SERVICES=portal,api,pdf ./scripts/verify-public-deploy-meta.sh
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
META_URL="${META_URL:-https://papermantra.com/deploy-meta.json}"
SERVICES="${SERVICES:-portal,api,pdf}"
ATTEMPTS="${ATTEMPTS:-12}"
SLEEP_SECS="${SLEEP_SECS:-15}"

if [[ -f "${ROOT_DIR}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${ROOT_DIR}/.env"
  set +a
fi

tag_from_image() {
  local image="$1"
  if [[ "${image}" == *:* ]]; then
    echo "${image##*:}"
  else
    echo ""
  fi
}

expected_for() {
  case "$1" in
    portal) echo "${EXPECTED_PORTAL:-$(tag_from_image "${IMAGE_PAPERMANTRA:-}")}" ;;
    website) echo "${EXPECTED_WEBSITE:-$(tag_from_image "${IMAGE_ROBOFUME:-}")}" ;;
    api) echo "${EXPECTED_API:-$(tag_from_image "${IMAGE_SERVICES:-}")}" ;;
    pdf) echo "${EXPECTED_PDF:-$(tag_from_image "${IMAGE_PDF:-}")}" ;;
    *) echo "" ;;
  esac
}

json_running_tag() {
  local body="$1"
  local svc="$2"
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "${body}" | python3 -c "import json,sys; d=json.load(sys.stdin); print((d.get('running') or {}).get(sys.argv[1]) or '')" "${svc}"
  else
    # Fallback: first "svc": "tag" occurrence inside the file (good enough for our meta shape).
    echo "${body}" | tr '\n' ' ' | sed -n "s/.*\"${svc}\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -n1
  fi
}

IFS=',' read -r -a SVC_ARRAY <<< "${SERVICES}"

for i in $(seq 1 "${ATTEMPTS}"); do
  body="$(curl -fsS "${META_URL}" 2>/dev/null || true)"
  if [[ -z "${body}" ]]; then
    echo "Attempt ${i}/${ATTEMPTS}: deploy-meta not reachable yet"
    sleep "${SLEEP_SECS}"
    continue
  fi

  ok=1
  for svc in "${SVC_ARRAY[@]}"; do
    svc="$(echo "${svc}" | xargs)"
    [[ -z "${svc}" ]] && continue
    expected="$(expected_for "${svc}")"
    if [[ -z "${expected}" ]]; then
      echo "WARN: no expected tag for ${svc}, skipping"
      continue
    fi
    running="$(json_running_tag "${body}" "${svc}")"
    if [[ "${running}" != "${expected}" ]]; then
      echo "Attempt ${i}/${ATTEMPTS}: ${svc} running=${running:-?} expected=${expected}"
      ok=0
    else
      echo "OK ${svc}=${running}"
    fi
  done

  if [[ "${ok}" -eq 1 ]]; then
    echo "Public deploy-meta matches expected tags."
    exit 0
  fi
  sleep "${SLEEP_SECS}"
done

echo "ERROR: deploy-meta did not report expected image tags in time."
echo "This usually means SSH deploy failed and pull-deploy did not recreate containers."
exit 1
