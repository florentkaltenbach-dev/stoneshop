#!/bin/bash
# WordPress Daily Update Script
# Runs plugin, theme, and core updates via WP-CLI

set -e

LOG_FILE="/opt/dockbase/logs/wp-updates.log"
CONTAINER="dockbase_frankenphp"
WP_CMD="wp --path=/app/web/wp"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "========== Starting WordPress Update =========="

# Check if container is running
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
    log "ERROR: Container $CONTAINER is not running"
    exit 1
fi

# Update WordPress core
log "Checking WordPress core updates..."
docker exec $CONTAINER $WP_CMD core update 2>&1 | tee -a "$LOG_FILE" || true

# Update all plugins
log "Updating plugins..."
docker exec $CONTAINER $WP_CMD plugin update --all 2>&1 | tee -a "$LOG_FILE" || true

# Update all themes
log "Updating themes..."
docker exec $CONTAINER $WP_CMD theme update --all 2>&1 | tee -a "$LOG_FILE" || true

# Update WooCommerce database if needed
log "Checking WooCommerce database..."
docker exec $CONTAINER $WP_CMD wc update 2>&1 | tee -a "$LOG_FILE" || true

# Clear caches
log "Clearing caches..."
docker exec $CONTAINER $WP_CMD cache flush 2>&1 | tee -a "$LOG_FILE" || true
docker exec dockbase_keydb keydb-cli FLUSHALL 2>&1 | tee -a "$LOG_FILE" || true

log "========== WordPress Update Complete =========="
