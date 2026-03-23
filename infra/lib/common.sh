#!/usr/bin/env bash
# Dockbase shared library — sourced by all infra scripts
# Usage: source "$(dirname "$0")/lib/common.sh"  (from infra/)
#    or: source "${INSTALL_DIR}/infra/lib/common.sh"  (from cron/other)

set -euo pipefail

# ── Paths ──────────────────────────────────────────────────
INSTALL_DIR="${INSTALL_DIR:-/opt/dockbase}"
DOCKBASE_NETWORK="dockbase-proxy"
CONFIG_FILE="${INSTALL_DIR}/config.env"
STATE_FILE="${INSTALL_DIR}/.deploy-state"

# ── Config ─────────────────────────────────────────────────
load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "Config file not found: ${CONFIG_FILE}"
        exit 1
    fi
    set -a
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    set +a
}

require_var() {
    local var_name="$1"
    if [ -z "${!var_name:-}" ]; then
        log_error "Required variable ${var_name} is not set in ${CONFIG_FILE}"
        exit 1
    fi
}

# ── Guards ─────────────────────────────────────────────────
require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

# ── Logging ────────────────────────────────────────────────
_log() {
    local level="$1"; shift
    printf "[%s] [%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*"
}

log_info()  { _log "INFO"  "$@"; }
log_warn()  { _log "WARN"  "$@" >&2; }
log_error() { _log "ERROR" "$@" >&2; }

# ── Container healthcheck gate ─────────────────────────────
# Usage: wait_healthy [compose_dir] [timeout_seconds]
# Waits until all containers in the compose project are healthy.
wait_healthy() {
    local compose_dir="${1:-$INSTALL_DIR}"
    local timeout="${2:-300}"
    local waited=0

    log_info "Waiting for containers to become healthy (timeout: ${timeout}s)..."

    while true; do
        local unhealthy
        unhealthy=$(cd "$compose_dir" && docker compose ps --format json 2>/dev/null \
            | jq -r 'select(.Health != null and .Health != "healthy" and .Health != "") | .Name' 2>/dev/null \
            | head -20)

        if [ -z "$unhealthy" ]; then
            log_info "All containers healthy."
            return 0
        fi

        if [ "$waited" -ge "$timeout" ]; then
            log_error "Timeout waiting for containers. Unhealthy:"
            echo "$unhealthy" >&2
            return 1
        fi

        sleep 5
        waited=$((waited + 5))
        if (( waited % 30 == 0 )); then
            log_info "Still waiting (${waited}s)... unhealthy: $(echo "$unhealthy" | tr '\n' ' ')"
        fi
    done
}

# ── Restic wrapper ─────────────────────────────────────────
# Ensures RESTIC_REPOSITORY and RESTIC_PASSWORD are passed through sudo.
run_restic() {
    RESTIC_REPOSITORY="${RESTIC_REPOSITORY}" \
    RESTIC_PASSWORD="${RESTIC_PASSWORD}" \
    restic "$@"
}
