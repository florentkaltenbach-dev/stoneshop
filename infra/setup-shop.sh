#!/usr/bin/env bash
set -euo pipefail

# Dockbase Phase 4: Shop stack
# Builds and starts the WooCommerce shop (FrankenPHP, MariaDB, KeyDB, Matomo).
# Run as root on the server after setup.sh and setup-caddy.sh.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_root
load_config

log_info "=== Setting up shop stack ==="

cd "${INSTALL_DIR}"

# ── Ensure directories exist ────────────────────────────
mkdir -p "${INSTALL_DIR}/logs/frankenphp"
chown deploy:dockbase "${INSTALL_DIR}/logs/frankenphp"

mkdir -p "${INSTALL_DIR}/web/app/uploads" "${INSTALL_DIR}/web/app/languages"
chown -R 33:1100 "${INSTALL_DIR}/web/app/uploads" "${INSTALL_DIR}/web/app/languages"
chmod 2775 "${INSTALL_DIR}/web/app/uploads" "${INSTALL_DIR}/web/app/languages"

# ── Ensure dockbase-proxy network exists ────────────────
if ! docker network inspect "${DOCKBASE_NETWORK}" &>/dev/null; then
    docker network create "${DOCKBASE_NETWORK}"
    log_info "Created Docker network: ${DOCKBASE_NETWORK}"
fi

# ── Build & Start Shop ─────────────────────────────────
log_info "Building shop image..."
docker compose build

log_info "Starting shop services..."
docker compose up -d

# ── Wait for healthy ────────────────────────────────────
wait_healthy "${INSTALL_DIR}" 300

# ── Verify FrankenPHP responds ──────────────────────────
log_info "Verifying FrankenPHP on internal port 8080..."
if docker exec dockbase_frankenphp curl -sf -o /dev/null http://localhost:8080/ 2>/dev/null; then
    log_info "FrankenPHP responding on :8080"
else
    log_warn "FrankenPHP not yet responding on :8080 (may need more startup time)"
fi

log_info "Shop stack setup complete."
docker compose ps
