#!/bin/bash
# StoneShop Data Import — Phase 3
# Restores data from Restic backups and runs search-replace if domain changed.
# Run as root after setup.sh has the stack running.
# Usage: sudo bash import.sh

set -Eeuo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Must run as root" >&2
    exit 1
fi

INSTALL_DIR="/opt/stoneshop"
CONFIG_ENV="$INSTALL_DIR/config.env"
CONTAINER="stoneshop_frankenphp"
DB_CONTAINER="stoneshop_mariadb"

if [ ! -f "$CONFIG_ENV" ]; then
    echo "ERROR: ${CONFIG_ENV} not found" >&2
    exit 1
fi

# Source config for env vars
set -a
source "$CONFIG_ENV"
set +a

# Helper: create temp dir writable by deploy user
make_tmp() {
    local d
    d=$(mktemp -d)
    chmod 777 "$d"
    echo "$d"
}

# Helper: run restic as deploy user with repo credentials
# (sudo strips environment, so we pass vars explicitly)
run_restic() {
    sudo -u deploy \
        RESTIC_REPOSITORY="$RESTIC_REPOSITORY" \
        RESTIC_PASSWORD="$RESTIC_PASSWORD" \
        restic "$@"
}

# ── Ensure StorageBox SSH config exists ───────────────────
DEPLOY_SSH_DIR="/home/deploy/.ssh"
BACKUP_KEY="$INSTALL_DIR/config/backup/backup_key"
if [ -n "${STORAGEBOX_HOST:-}" ] && ! grep -q "Host storagebox" "$DEPLOY_SSH_DIR/config" 2>/dev/null; then
    echo "StorageBox SSH config missing — creating it..."
    mkdir -p "$DEPLOY_SSH_DIR"
    cat >> "$DEPLOY_SSH_DIR/config" <<SSHCFG

Host storagebox
    HostName ${STORAGEBOX_HOST}
    User ${STORAGEBOX_USER}
    Port ${STORAGEBOX_PORT:-23}
    IdentityFile ${BACKUP_KEY}
    StrictHostKeyChecking accept-new
SSHCFG
    chmod 0600 "$DEPLOY_SSH_DIR/config"
    chown -R deploy:deploy "$DEPLOY_SSH_DIR"
    sudo -u deploy ssh-keyscan -p "${STORAGEBOX_PORT:-23}" "$STORAGEBOX_HOST" >> "$DEPLOY_SSH_DIR/known_hosts" 2>/dev/null || true
    echo "StorageBox SSH configured."
fi

echo "=== StoneShop Data Import ==="

# ── Healthcheck Gate ──────────────────────────────────────
echo "Waiting for all containers to be healthy..."
TIMEOUT=300
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
    UNHEALTHY=$(cd "$INSTALL_DIR" && docker compose ps --format json 2>/dev/null | \
        jq -r 'select(.Health != "healthy" and .Health != "" and .Health != null) | .Name' 2>/dev/null | wc -l || echo "0")
    if [ "$UNHEALTHY" -eq 0 ]; then
        echo "All containers healthy."
        break
    fi
    echo "  Waiting... (${ELAPSED}s / ${TIMEOUT}s)"
    sleep 10
    ELAPSED=$((ELAPSED + 10))
done

if [ $ELAPSED -ge $TIMEOUT ]; then
    echo "ERROR: Containers not healthy after ${TIMEOUT}s" >&2
    cd "$INSTALL_DIR" && docker compose ps
    exit 1
fi

# ── Restore Uploads ───────────────────────────────────────
echo "Restoring uploads from Restic..."
RESTORE_TMP=$(make_tmp)
run_restic --retry-lock 5m restore latest --tag uploads --target "$RESTORE_TMP"

if [ -d "$RESTORE_TMP/backups/uploads" ]; then
    rsync -a --delete "$RESTORE_TMP/backups/uploads/" "$INSTALL_DIR/web/app/uploads/"
    echo "Uploads restored."
else
    echo "WARNING: No uploads directory found in snapshot." >&2
fi

# ── Restore Languages ────────────────────────────────────
echo "Restoring languages from Restic..."
LANG_TMP=$(make_tmp)
run_restic --retry-lock 5m restore latest --tag languages --target "$LANG_TMP" 2>/dev/null || true

if [ -d "$LANG_TMP/backups/languages" ]; then
    rsync -a --delete "$LANG_TMP/backups/languages/" "$INSTALL_DIR/web/app/languages/"
    echo "Languages restored."
else
    echo "INFO: No languages snapshot found (may not exist yet). Skipping."
fi

# ── Restore Database ─────────────────────────────────────
echo "Restoring database from Restic..."
DB_TMP=$(make_tmp)
run_restic --retry-lock 5m restore latest --tag db --target "$DB_TMP"

if [ -f "$DB_TMP/backups/db/stoneshop.sql" ]; then
    echo "Importing stoneshop database..."
    docker exec -i "$DB_CONTAINER" mariadb -u root -p"$MYSQL_ROOT_PASSWORD" stoneshop \
        < "$DB_TMP/backups/db/stoneshop.sql"
    echo "WordPress database imported."
else
    echo "ERROR: stoneshop.sql not found in snapshot." >&2
    exit 1
fi

if [ -f "$DB_TMP/backups/db/matomo.sql" ]; then
    echo "Importing matomo database..."
    docker exec -i "$DB_CONTAINER" mariadb -u root -p"$MYSQL_ROOT_PASSWORD" matomo \
        < "$DB_TMP/backups/db/matomo.sql"
    echo "Matomo database imported."
else
    echo "WARNING: matomo.sql not found in snapshot." >&2
fi

# ── Restore Matomo Data Volume ───────────────────────────
echo "Restoring Matomo data volume from Restic..."
MATOMO_TMP=$(make_tmp)
run_restic --retry-lock 5m restore latest --tag matomo --target "$MATOMO_TMP" 2>/dev/null || true

if [ -d "$MATOMO_TMP/backups/matomo" ]; then
    # Copy into the matomo_data volume via the matomo container
    docker cp "$MATOMO_TMP/backups/matomo/." stoneshop_matomo:/var/www/html/
    docker exec stoneshop_matomo chown -R www-data:www-data /var/www/html
    echo "Matomo data volume restored."
else
    echo "INFO: No matomo data snapshot found. Skipping."
fi

# ── Fix Ownership ─────────────────────────────────────────
echo "Fixing file ownership..."
chown -R 33:1100 "$INSTALL_DIR/web/app/uploads" "$INSTALL_DIR/web/app/languages"
chmod -R g+w "$INSTALL_DIR/web/app/uploads" "$INSTALL_DIR/web/app/languages"

# ── Domain Search-Replace ─────────────────────────────────
if [ -n "${OLD_DOMAIN:-}" ] && [ -n "${SITE_DOMAIN:-}" ] && [ "$OLD_DOMAIN" != "$SITE_DOMAIN" ]; then
    echo "Running WordPress search-replace: ${OLD_DOMAIN} → ${SITE_DOMAIN}..."
    docker exec "$CONTAINER" wp --path=/app/web/wp search-replace \
        "https://$OLD_DOMAIN" "https://$SITE_DOMAIN" --all-tables --precise

    docker exec "$CONTAINER" wp --path=/app/web/wp search-replace \
        "$OLD_DOMAIN" "$SITE_DOMAIN" --all-tables --precise

    echo "Updating Matomo site URL..."
    docker exec -i "$DB_CONTAINER" mariadb -u root -p"$MYSQL_ROOT_PASSWORD" matomo <<SQLEOF
UPDATE matomo_site SET main_url='https://${SITE_DOMAIN}' WHERE idsite=1;
SQLEOF
    echo "Domain migration complete."
else
    echo "No domain change detected (OLD_DOMAIN == SITE_DOMAIN). Skipping search-replace."
fi

# ── Fix Matomo Currency ───────────────────────────────────
echo "Setting Matomo currency to EUR..."
docker exec -i "$DB_CONTAINER" mariadb -u root -p"$MYSQL_ROOT_PASSWORD" matomo <<'SQLEOF'
UPDATE matomo_site SET currency='EUR' WHERE idsite=1;
SQLEOF

# ── Flush Caches ─────────────────────────────────────────
echo "Flushing caches..."
docker exec "$CONTAINER" wp --path=/app/web/wp cache flush 2>/dev/null || true
docker exec stoneshop_keydb keydb-cli FLUSHALL 2>/dev/null || true

# ── Cleanup ───────────────────────────────────────────────
rm -rf "$RESTORE_TMP" "$LANG_TMP" "$DB_TMP" "$MATOMO_TMP"

# ── Final Healthcheck ─────────────────────────────────────
echo "Running final healthcheck..."
sleep 5
cd "$INSTALL_DIR"
SITE_STATUS=$(docker exec "$CONTAINER" curl -s -o /dev/null -w '%{http_code}' http://localhost/ 2>/dev/null || echo "000")

if [ "$SITE_STATUS" = "200" ] || [ "$SITE_STATUS" = "302" ]; then
    echo "Site responding (HTTP ${SITE_STATUS})."
else
    echo "WARNING: Site returned HTTP ${SITE_STATUS}. Check logs." >&2
fi

echo ""
echo "=== Import complete ==="
echo ""
echo "Verify:"
echo "  curl -I https://${SITE_DOMAIN}"
echo "  curl -I https://matomo.${SITE_DOMAIN}"
echo ""
echo "If OLD_DOMAIN was set, you can remove it from config.env now."
