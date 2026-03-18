#!/bin/bash
# StoneShop Backup Script
# Backs up: databases (tag: db), uploads (tag: uploads),
#           languages (tag: languages), matomo volume (tag: matomo)
# Always runs as `deploy` user.

set -Eeuo pipefail

# Enforce consistent user context so SSH alias `storagebox` resolves the same way.
if [ "$(id -un)" != "deploy" ]; then
    exec sudo -u deploy -H bash "$0" "$@"
fi

cd /opt/stoneshop

LOG_FILE="logs/backup.log"
LOCK_FILE="/var/lock/stoneshop-backup.lock"
BACKUP_DIR="backups/db"
UPLOADS_BACKUP_DIR="backups/uploads"
LANGUAGES_BACKUP_DIR="backups/languages"
MATOMO_BACKUP_DIR="backups/matomo"

log() {
    echo "$(date '+%a %b %d %T %Z %Y'): $*" >> "$LOG_FILE"
}

load_env_var() {
    local key="$1"
    local value

    value="$(grep -m1 "^${key}=" config.env 2>/dev/null | cut -d= -f2- || true)"
    if [ -z "$value" ]; then
        log "ERROR - Missing ${key} in /opt/stoneshop/config.env"
        exit 1
    fi

    export "${key}=${value}"
}

mkdir -p logs "$BACKUP_DIR" "$UPLOADS_BACKUP_DIR" "$LANGUAGES_BACKUP_DIR" "$MATOMO_BACKUP_DIR"

# Prevent overlapping local runs (cron + manual).
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    log "Another backup run is active, skipping."
    exit 0
fi

trap 'rc=$?; log "ERROR - Backup failed (line ${LINENO}, exit ${rc})"; exit $rc' ERR

load_env_var MYSQL_ROOT_PASSWORD
load_env_var RESTIC_REPOSITORY
load_env_var RESTIC_PASSWORD

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

log "Starting backup..."

# Clean stale remote locks from interrupted historical runs.
if ! restic unlock >> "$LOG_FILE" 2>&1; then
    log "Warning - restic unlock returned non-zero, continuing."
fi

# ── Database Dumps ────────────────────────────────────────
log "Dumping databases..."
docker compose exec -T mariadb mariadb-dump -u root -p"$MYSQL_ROOT_PASSWORD" \
    --single-transaction stoneshop > "$BACKUP_DIR/stoneshop.sql" 2>> "$LOG_FILE"
docker compose exec -T mariadb mariadb-dump -u root -p"$MYSQL_ROOT_PASSWORD" \
    --single-transaction matomo > "$BACKUP_DIR/matomo.sql" 2>> "$LOG_FILE"

log "Backing up database dumps..."
restic --retry-lock 5m backup "$BACKUP_DIR/" --tag db >> "$LOG_FILE" 2>&1

# ── Uploads ───────────────────────────────────────────────
log "Backing up uploads..."
rm -rf "$UPLOADS_BACKUP_DIR"/*
docker cp stoneshop_frankenphp:/app/web/app/uploads/. "$UPLOADS_BACKUP_DIR/" 2>> "$LOG_FILE"
restic --retry-lock 5m backup "$UPLOADS_BACKUP_DIR/" --tag uploads >> "$LOG_FILE" 2>&1

# ── Languages ─────────────────────────────────────────────
log "Backing up languages..."
rm -rf "$LANGUAGES_BACKUP_DIR"/*
docker cp stoneshop_frankenphp:/app/web/app/languages/. "$LANGUAGES_BACKUP_DIR/" 2>> "$LOG_FILE" || true
if [ "$(ls -A "$LANGUAGES_BACKUP_DIR" 2>/dev/null)" ]; then
    restic --retry-lock 5m backup "$LANGUAGES_BACKUP_DIR/" --tag languages >> "$LOG_FILE" 2>&1
else
    log "Languages directory empty, skipping Restic backup for languages."
fi

# ── Matomo Volume ─────────────────────────────────────────
log "Backing up Matomo data volume..."
rm -rf "$MATOMO_BACKUP_DIR"/*
docker cp stoneshop_matomo:/var/www/html/. "$MATOMO_BACKUP_DIR/" 2>> "$LOG_FILE"
restic --retry-lock 5m backup "$MATOMO_BACKUP_DIR/" --tag matomo >> "$LOG_FILE" 2>&1

# ── Retention ─────────────────────────────────────────────
log "Applying retention policy..."
if ! restic unlock >> "$LOG_FILE" 2>&1; then
    log "Warning - pre-prune restic unlock returned non-zero, continuing."
fi
if ! restic --retry-lock 5m forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune >> "$LOG_FILE" 2>&1; then
    log "Warning - Retention/prune failed; snapshots were still created."
fi

log "Backup completed successfully"
echo "---" >> "$LOG_FILE"
