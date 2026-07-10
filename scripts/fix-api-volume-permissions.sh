#!/usr/bin/env bash
# =============================================================================
# Ensure API writable volumes are owned by appuser (uid=100, gid=101).
#
# Required after base-image changes (e.g. Alpine → Jammy) where the runtime
# user UID can drift and break log/upload/backup volumes created under uid 100.
#
# Usage:
#   ./scripts/fix-api-volume-permissions.sh
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

PROJECT="${COMPOSE_PROJECT_NAME:-papermantra}"
API_UID=100
API_GID=101

volumes=(
  "${PROJECT}_api_logs"
  "${PROJECT}_api_user_pics"
  "${PROJECT}_api_user_uploads"
  "${PROJECT}_api_backups"
)

for vol in "${volumes[@]}"; do
  if ! docker volume inspect "${vol}" >/dev/null 2>&1; then
    echo "   skip ${vol} (not found)"
    continue
  fi
  echo ">> Fixing permissions on ${vol} (uid=${API_UID}, gid=${API_GID})..."
  docker run --rm \
    -v "${vol}:/data" \
    alpine:3.20 \
    sh -c "chown -R ${API_UID}:${API_GID} /data && chmod -R u+rwX,g+rwX /data"
done

echo ">> API volume permissions updated."
