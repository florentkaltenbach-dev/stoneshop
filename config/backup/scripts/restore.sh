#!/bin/bash
# StoneShop Restore Script
# Restores individual backup tags from Restic.
# Usage: ./restore.sh [tag] [snapshot-id]
# Tags: db, uploads, languages, matomo
# If no tag given, lists all snapshots.

set -Eeuo pipefail

# Keep Restic user context consistent with backup script and cron.
if [ "$(id -un)" != "deploy" ]; then
    exec sudo -u deploy -H bash "$0" "$@"
fi

cd /opt/stoneshop

load_env_var() {
    local key="$1"
    local value

    value="$(grep -m1 "^${key}=" config.env 2>/dev/null | cut -d= -f2- || true)"
    if [ -z "$value" ]; then
        echo "ERROR: Missing ${key} in /opt/stoneshop/config.env" >&2
        exit 1
    fi

    export "${key}=${value}"
}

load_env_var RESTIC_REPOSITORY
load_env_var RESTIC_PASSWORD

# Remove stale locks from interrupted runs.
restic unlock >/dev/null 2>&1 || true

if [ -z "${1:-}" ]; then
    echo "Available snapshots:"
    echo ""
    for tag in db uploads languages matomo; do
        echo "=== ${tag} ==="
        restic --retry-lock 5m snapshots --tag "$tag" 2>/dev/null || echo "  (none)"
        echo ""
    done
    echo "Usage: $0 <tag> [snapshot-id]"
    echo "Tags: db, uploads, languages, matomo"
    echo "If snapshot-id is omitted, restores 'latest' for that tag."
    exit 0
fi

TAG="$1"
SNAPSHOT_ID="${2:-latest}"
TARGET_DIR="/tmp/restore-${TAG}-$(date +%Y%m%d-%H%M%S)"

case "$TAG" in
    db|uploads|languages|matomo) ;;
    *)
        echo "ERROR: Unknown tag '$TAG'. Valid tags: db, uploads, languages, matomo" >&2
        exit 1
        ;;
esac

echo "Restoring tag '${TAG}' (snapshot: ${SNAPSHOT_ID}) to ${TARGET_DIR}..."
mkdir -p "$TARGET_DIR"
restic --retry-lock 5m restore "$SNAPSHOT_ID" --tag "$TAG" --target "$TARGET_DIR"

echo ""
echo "Restore complete. Files at: $TARGET_DIR"
echo ""

case "$TAG" in
    db)
        echo "To import WordPress DB:"
        echo "  docker compose exec -T mariadb mariadb -u root -p\$MYSQL_ROOT_PASSWORD stoneshop < ${TARGET_DIR}/backups/db/stoneshop.sql"
        echo ""
        echo "To import Matomo DB:"
        echo "  docker compose exec -T mariadb mariadb -u root -p\$MYSQL_ROOT_PASSWORD matomo < ${TARGET_DIR}/backups/db/matomo.sql"
        ;;
    uploads)
        echo "To restore uploads:"
        echo "  rsync -a --delete ${TARGET_DIR}/backups/uploads/ /opt/stoneshop/web/app/uploads/"
        echo "  chown -R 33:1100 /opt/stoneshop/web/app/uploads"
        ;;
    languages)
        echo "To restore languages:"
        echo "  rsync -a --delete ${TARGET_DIR}/backups/languages/ /opt/stoneshop/web/app/languages/"
        echo "  chown -R 33:1100 /opt/stoneshop/web/app/languages"
        ;;
    matomo)
        echo "To restore Matomo data:"
        echo "  docker cp ${TARGET_DIR}/backups/matomo/. stoneshop_matomo:/var/www/html/"
        echo "  docker exec stoneshop_matomo chown -R www-data:www-data /var/www/html"
        ;;
esac
