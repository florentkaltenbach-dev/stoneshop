#!/bin/bash
# Dockbase Backup Script
# Mode-aware: reads DEPLOY_MODE from config.env, only backs up active stacks.
#
# Tags: shop-db, shop-files, shop-matomo, web-files, web-matomo, mailcow
# Always runs as `deploy` user.

set -Eeuo pipefail

# Enforce consistent user context
if [ "$(id -un)" != "deploy" ]; then
    exec sudo -u deploy -H bash "$0" "$@"
fi

cd /opt/dockbase

LOG_FILE="logs/backup.log"
LOCK_FILE="/var/lock/dockbase-backup.lock"
TMP_BACKUP="/tmp/dockbase-backup-$$"

log() {
    echo "$(date '+%a %b %d %T %Z %Y'): $*" >> "$LOG_FILE"
}

load_env_var() {
    local key="$1"
    local value
    value="$(grep -m1 "^${key}=" config.env 2>/dev/null | cut -d= -f2- || true)"
    if [ -z "$value" ]; then
        log "ERROR - Missing ${key} in /opt/dockbase/config.env"
        exit 1
    fi
    export "${key}=${value}"
}

mode_includes() {
    case "$DEPLOY_MODE" in
        full) return 0 ;;
        "$1") return 0 ;;
        *) return 1 ;;
    esac
}

mkdir -p logs

# Prevent overlapping runs
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    log "Another backup run is active, skipping."
    exit 0
fi

trap 'rc=$?; rm -rf "$TMP_BACKUP"; log "ERROR - Backup failed (line ${LINENO}, exit ${rc})"; exit $rc' ERR
trap 'rm -rf "$TMP_BACKUP"' EXIT

load_env_var MYSQL_ROOT_PASSWORD
load_env_var RESTIC_REPOSITORY
load_env_var RESTIC_PASSWORD
load_env_var DEPLOY_MODE

# ── Healthcheck Gate ──────────────────────────────────────
log "Waiting for healthy containers..."
TIMEOUT=300
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
    UNHEALTHY=$(docker compose ps --format json 2>/dev/null | \
        jq -r 'select(.Health != "healthy" and .Health != "" and .Health != null) | .Name' 2>/dev/null | wc -l || echo "0")
    if [ "$UNHEALTHY" -eq 0 ]; then
        break
    fi
    sleep 10
    ELAPSED=$((ELAPSED + 10))
done

if [ $ELAPSED -ge $TIMEOUT ]; then
    log "ERROR - Containers not healthy after ${TIMEOUT}s, aborting."
    exit 1
fi

log "Starting backup (mode: ${DEPLOY_MODE})..."

# Clean stale remote locks
restic unlock >> "$LOG_FILE" 2>&1 || true

# ── Shop backup (if mode is full or shop) ────────────────
if mode_includes shop; then
    log "=== Shop backup ==="

    # shop-db: SQL dump of stoneshop database
    mkdir -p "${TMP_BACKUP}/shop-db"
    log "Dumping stoneshop database..."
    docker compose exec -T mariadb mariadb-dump -u root -p"$MYSQL_ROOT_PASSWORD" \
        --single-transaction stoneshop > "${TMP_BACKUP}/shop-db/stoneshop.sql" 2>> "$LOG_FILE"
    restic --retry-lock 5m backup "${TMP_BACKUP}/shop-db/" --tag shop-db >> "$LOG_FILE" 2>&1

    # shop-files: uploads + languages
    log "Backing up shop files (uploads + languages)..."
    mkdir -p "${TMP_BACKUP}/shop-files/uploads" "${TMP_BACKUP}/shop-files/languages"
    docker cp dockbase_frankenphp:/app/web/app/uploads/. "${TMP_BACKUP}/shop-files/uploads/" 2>> "$LOG_FILE"
    docker cp dockbase_frankenphp:/app/web/app/languages/. "${TMP_BACKUP}/shop-files/languages/" 2>> "$LOG_FILE" || true
    restic --retry-lock 5m backup "${TMP_BACKUP}/shop-files/" --tag shop-files >> "$LOG_FILE" 2>&1

    # shop-matomo: matomo_shop SQL + volume data
    log "Backing up shop Matomo..."
    mkdir -p "${TMP_BACKUP}/shop-matomo/data"
    docker compose exec -T mariadb mariadb-dump -u root -p"$MYSQL_ROOT_PASSWORD" \
        --single-transaction matomo_shop > "${TMP_BACKUP}/shop-matomo/matomo_shop.sql" 2>> "$LOG_FILE"
    docker cp dockbase_matomo_shop:/var/www/html/. "${TMP_BACKUP}/shop-matomo/data/" 2>> "$LOG_FILE"
    restic --retry-lock 5m backup "${TMP_BACKUP}/shop-matomo/" --tag shop-matomo >> "$LOG_FILE" 2>&1
fi

# ── Website backup (if mode is full or web) ──────────────
if mode_includes web; then
    log "=== Website backup ==="

    # web-files: website content
    if [ -d "/opt/dockbase/website/public" ]; then
        log "Backing up website files..."
        restic --retry-lock 5m backup /opt/dockbase/website/public/ --tag web-files >> "$LOG_FILE" 2>&1
    fi

    # web-matomo: matomo_web SQL + volume data
    log "Backing up web Matomo..."
    mkdir -p "${TMP_BACKUP}/web-matomo/data"
    docker compose exec -T mariadb mariadb-dump -u root -p"$MYSQL_ROOT_PASSWORD" \
        --single-transaction matomo_web > "${TMP_BACKUP}/web-matomo/matomo_web.sql" 2>> "$LOG_FILE" || true
    docker cp dockbase_matomo_web:/var/www/html/. "${TMP_BACKUP}/web-matomo/data/" 2>> "$LOG_FILE" || true
    if [ -f "${TMP_BACKUP}/web-matomo/matomo_web.sql" ]; then
        restic --retry-lock 5m backup "${TMP_BACKUP}/web-matomo/" --tag web-matomo >> "$LOG_FILE" 2>&1
    fi
fi

# ── Mailcow backup (if mode is full or mail) ─────────────
if mode_includes mail; then
    log "=== Mailcow backup ==="
    MAILCOW_DIR="/opt/mailcow"
    MAILCOW_BACKUP_DIR="/opt/mailcow-backup"

    if [ -d "$MAILCOW_DIR" ]; then
        log "Running Mailcow backup..."
        mkdir -p "$MAILCOW_BACKUP_DIR"
        cd "$MAILCOW_DIR"
        # Use Mailcow's own backup tooling
        MAILCOW_BACKUP_LOCATION="$MAILCOW_BACKUP_DIR" docker compose exec -T mailcowdockerized_backup_1 \
            /opt/backup_and_restore.sh backup all 2>> "$LOG_FILE" || {
            # Fallback: use the helper script directly
            bash "${MAILCOW_DIR}/helper-scripts/backup_and_restore.sh" backup all \
                --delete-days 0 2>> "$LOG_FILE" || log "Warning - Mailcow backup may have failed"
        }
        cd /opt/dockbase

        log "Snapshotting Mailcow backup to Restic..."
        restic --retry-lock 5m backup "$MAILCOW_BACKUP_DIR/" --tag mailcow >> "$LOG_FILE" 2>&1
    else
        log "Mailcow not installed at ${MAILCOW_DIR}, skipping."
    fi
fi

# ── Retention ─────────────────────────────────────────────
log "Applying retention policy..."
restic unlock >> "$LOG_FILE" 2>&1 || true
restic --retry-lock 5m forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune >> "$LOG_FILE" 2>&1 || \
    log "Warning - Retention/prune failed; snapshots were still created."

log "Backup completed successfully (mode: ${DEPLOY_MODE})"
echo "---" >> "$LOG_FILE"
