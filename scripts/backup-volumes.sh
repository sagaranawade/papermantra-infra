#!/usr/bin/env bash
# =============================================================================
# Backup MongoDB, Redis, and uploaded media volumes.
#
# Usage:
#   ./scripts/backup-volumes.sh
#   ./scripts/backup-volumes.sh /opt/backups/papermantra
#
# Schedule with cron (daily at 02:00 UTC):
#   0 2 * * * /opt/papermantra-infra/scripts/backup-volumes.sh >> /var/log/papermantra-backup.log 2>&1
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

if [[ ! -f .env ]]; then
  echo "ERROR: .env not found."
  exit 1
fi

# shellcheck disable=SC1091
source .env

BACKUP_ROOT="${1:-${ROOT_DIR}/backups}"
TIMESTAMP="$(date -u +"%Y%m%dT%H%M%SZ")"
DEST="${BACKUP_ROOT}/${TIMESTAMP}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"

mkdir -p "${DEST}"

echo ">> Backing up MongoDB..."
docker compose exec -T mongodb mongodump \
  --username="${MONGO_ROOT_USER}" \
  --password="${MONGO_ROOT_PASSWORD}" \
  --authenticationDatabase=admin \
  --archive \
  --gzip > "${DEST}/mongodb.archive.gz"

echo ">> Backing up Redis RDB..."
docker compose exec -T redis redis-cli -a "${REDIS_PASSWORD}" --no-auth-warning BGSAVE
sleep 2
docker cp papermantra-redis:/data/dump.rdb "${DEST}/redis-dump.rdb" 2>/dev/null || \
  docker cp papermantra-redis:/data/appendonly.aof "${DEST}/redis-appendonly.aof" 2>/dev/null || \
  echo "WARN: Could not copy Redis data file"

echo ">> Archiving uploaded media volumes..."
docker run --rm \
  -v papermantra_api_user_pics:/data/user_pics:ro \
  -v papermantra_api_question_images:/data/images:ro \
  -v papermantra_pdf_images:/data/pdf_images:ro \
  -v "${DEST}:/backup" \
  alpine:3.20 \
  sh -c 'tar czf /backup/media-volumes.tar.gz -C /data .'

echo ">> Writing manifest..."
cat > "${DEST}/manifest.txt" <<EOF
timestamp=${TIMESTAMP}
compose_project=${COMPOSE_PROJECT_NAME:-papermantra}
mongodb_database=${MONGODB_DATABASE}
pdf_mongodb_database=${PDF_MONGODB_DATABASE}
EOF

echo ">> Pruning backups older than ${RETENTION_DAYS} days..."
find "${BACKUP_ROOT}" -mindepth 1 -maxdepth 1 -type d -mtime "+${RETENTION_DAYS}" -exec rm -rf {} +

echo ">> Backup saved to ${DEST}"
