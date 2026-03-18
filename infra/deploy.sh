#!/usr/bin/env bash
set -euo pipefail

# StoneShop One-Click Deploy
# Run from your laptop: ./deploy.sh <server-ip>
#
# State is tracked in .deploy-state next to this script.
# Safe to re-run — completed phases are skipped.
# Use --reset to start over from scratch.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"
BACKUP_KEY="${SCRIPT_DIR}/backup_key"
STATE_FILE="${SCRIPT_DIR}/.deploy-state"

# ── Parse arguments ─────────────────────────────────────
FRESH=false
RESET=false
for arg in "$@"; do
    case "$arg" in
        --fresh) FRESH=true ;;
        --reset) RESET=true ;;
    esac
done

POSITIONAL=()
for arg in "$@"; do
    case "$arg" in
        --fresh|--reset) ;;
        *) POSITIONAL+=("$arg") ;;
    esac
done

if [ ${#POSITIONAL[@]} -lt 1 ]; then
    echo "Usage: ./deploy.sh [--fresh] [--reset] <server-ip>"
    echo ""
    echo "Options:"
    echo "  --fresh     Clear known_hosts for this IP (use after server rebuild)"
    echo "  --reset     Clear deploy state and start all phases from scratch"
    echo ""
    echo "Optional files (place next to deploy.sh):"
    echo "  config.env  — site config + secrets (generated if missing)"
    echo "  backup_key  — StorageBox SSH key (skipped if missing)"
    echo ""
    echo "State is saved in .deploy-state. Re-runs skip completed phases."
    exit 1
fi

SERVER_IP="${POSITIONAL[0]}"
SERVER_IP="${SERVER_IP#*@}"

if [ "$FRESH" = true ]; then
    echo "Clearing known_hosts for ${SERVER_IP} (--fresh)..."
    ssh-keygen -R "$SERVER_IP" 2>/dev/null || true
    echo "Accepting new host key for ${SERVER_IP}..."
    for user in root deploy; do
        ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
            ${SSH_KEY:+-i "$SSH_KEY"} \
            "${user}@${SERVER_IP}" "echo ok" < /dev/null 2>/dev/null && break
    done || true
fi

if [ "$RESET" = true ]; then
    echo "Clearing deploy state (--reset)..."
    rm -f "$STATE_FILE"
fi

# ── State tracking ────────────────────────────────────────
phase_done() {
    grep -qx "$1" "$STATE_FILE" 2>/dev/null
}

mark_done() {
    echo "$1" >> "$STATE_FILE"
    echo ""
    echo "  >>> checkpoint: $1 done <<<"
    echo ""
}

last_checkpoint() {
    if [ -f "$STATE_FILE" ]; then
        tail -1 "$STATE_FILE"
    else
        echo "(none)"
    fi
}

if [ -f "$STATE_FILE" ]; then
    echo "Last checkpoint: $(last_checkpoint)"
    echo "Completed: $(paste -sd', ' "$STATE_FILE")"
    echo ""
fi

# ── Detect SSH key ────────────────────────────────────────
SSH_KEY=""
for candidate in "${SCRIPT_DIR}/id_ed25519_hetzner" \
                 ~/.ssh/id_ed25519_hetzner \
                 ~/.ssh/id_ed25519 \
                 ~/.ssh/id_rsa; do
    if [ -f "$candidate" ]; then
        SSH_KEY="$candidate"
        break
    fi
done

SSH_PROBE="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=5"
SSH_RUN="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
if [ -n "$SSH_KEY" ]; then
    SSH_PROBE="${SSH_PROBE} -i ${SSH_KEY}"
    SSH_RUN="${SSH_RUN} -i ${SSH_KEY}"
    echo "Using SSH key: ${SSH_KEY}"
fi

# ── Ensure config.env exists ────────────────────────────
if [ ! -f "$CONFIG_FILE" ]; then
    echo "No config.env found next to deploy.sh."
    echo "Generating from template..."
    cp "${REPO_DIR}/config.env.example" "$CONFIG_FILE"

    generate_password() { openssl rand -base64 24 | tr -d '/+=' | head -c 32; }

    sed -i "s/^MYSQL_ROOT_PASSWORD=changeme$/MYSQL_ROOT_PASSWORD=$(generate_password)/" "$CONFIG_FILE"
    sed -i "s/^MYSQL_PASSWORD=changeme$/MYSQL_PASSWORD=$(generate_password)/" "$CONFIG_FILE"
    sed -i "s/^MATOMO_DATABASE_PASSWORD=changeme$/MATOMO_DATABASE_PASSWORD=$(generate_password)/" "$CONFIG_FILE"
    sed -i "s/^RESTIC_PASSWORD=changeme$/RESTIC_PASSWORD=$(generate_password)/" "$CONFIG_FILE"

    for key in AUTH_KEY SECURE_AUTH_KEY LOGGED_IN_KEY NONCE_KEY AUTH_SALT SECURE_AUTH_SALT LOGGED_IN_SALT NONCE_SALT; do
        sed -i "s/^${key}=$/${key}=$(openssl rand -base64 48 | tr -d '/+=' | head -c 64)/" "$CONFIG_FILE"
    done

    echo ""
    echo "Generated: ${CONFIG_FILE}"
    echo ""
    echo ">>> EDIT THIS FILE NOW <<<"
    echo "At minimum, set:"
    echo "  SITE_DOMAIN       — your actual domain"
    echo "  TLS_EMAIL         — your email for Let's Encrypt"
    echo "  OLD_DOMAIN        — previous domain (for migration)"
    echo ""
    read -r -p "Press Enter when ready (or Ctrl+C to abort)..."

    if grep -q "stoneshop.example.com" "$CONFIG_FILE"; then
        echo ""
        echo "WARNING: SITE_DOMAIN is still the default placeholder."
        read -r -p "Continue anyway? [y/N] " yn
        case "$yn" in
            [Yy]*) ;;
            *) echo "Aborted. Edit config.env and re-run."; exit 1 ;;
        esac
    fi
fi

source "$CONFIG_FILE"
: "${SITE_DOMAIN:?SITE_DOMAIN not set in config.env}"
: "${TLS_EMAIL:?TLS_EMAIL not set in config.env}"

echo ""
echo "=== StoneShop Deploy ==="
echo "Server:  ${SERVER_IP}"
echo "Domain:  ${SITE_DOMAIN}"
echo "Config:  ${CONFIG_FILE}"
echo ""

# ── Helpers ─────────────────────────────────────────────

ssh_probe() {
    local user="$1"; shift
    # shellcheck disable=SC2086
    ssh $SSH_PROBE "${user}@${SERVER_IP}" "$@" < /dev/null
}

ssh_as() {
    local user="$1"; shift
    # shellcheck disable=SC2086
    ssh $SSH_RUN "${user}@${SERVER_IP}" "$@"
}

# Upload a local script, then execute it
run_script() {
    local user="$1" phase_name="$2" local_script="$3"
    shift 3
    local env_prefix="${*:-}"

    echo "[${phase_name}] Uploading $(basename "$local_script")..."
    local scp_opts="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
    [ -n "$SSH_KEY" ] && scp_opts="${scp_opts} -i ${SSH_KEY}"
    # shellcheck disable=SC2086
    scp $scp_opts "$local_script" "${user}@${SERVER_IP}:/tmp/_phase_script.sh"

    echo "[${phase_name}] Running..."
    local rc=0
    # shellcheck disable=SC2086
    ssh $SSH_RUN "${user}@${SERVER_IP}" "${env_prefix:+$env_prefix }bash /tmp/_phase_script.sh; rm -f /tmp/_phase_script.sh" || rc=$?

    if [ "$rc" -ne 0 ]; then
        echo ""
        echo "ERROR: ${phase_name} failed (exit code ${rc})."
        echo "SSH into the server to investigate:"
        echo "  ssh deploy@${SERVER_IP}"
        exit "$rc"
    fi
}

run_remote_cmd() {
    local user="$1" phase_name="$2"; shift 2
    echo "[${phase_name}] Running..."
    local rc=0
    # shellcheck disable=SC2086
    ssh $SSH_RUN "${user}@${SERVER_IP}" "$@" || rc=$?

    if [ "$rc" -ne 0 ]; then
        echo ""
        echo "ERROR: ${phase_name} failed (exit code ${rc})."
        exit "$rc"
    fi
}

wait_for_ssh() {
    local user="$1"
    local max_wait=30
    local waited=0
    echo "Waiting for SSH as ${user}@${SERVER_IP}..."
    while ! ssh_probe "$user" "echo ok" &>/dev/null; do
        sleep 5
        waited=$((waited + 5))
        if [ $waited -ge $max_wait ]; then
            echo "ERROR: SSH not available after ${max_wait}s"
            exit 1
        fi
        echo "  ...waiting (${waited}s)"
    done
    echo "SSH ready."
}

upload_file() {
    local src="$1" dest="$2" user="${3:-deploy}" mode="${4:-644}"
    local scp_opts="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
    [ -n "$SSH_KEY" ] && scp_opts="${scp_opts} -i ${SSH_KEY}"
    # shellcheck disable=SC2086
    scp $scp_opts "$src" "${user}@${SERVER_IP}:/tmp/_upload"
    ssh_as "$user" "sudo mv /tmp/_upload ${dest} && sudo chmod ${mode} ${dest}"
}

# ── Detect SSH user ──────────────────────────────────────
echo "Waiting for SSH on ${SERVER_IP}..."
READY_USER=""
max_wait=30
waited=0
while [ -z "$READY_USER" ]; do
    if ssh_probe "deploy" "echo ok" &>/dev/null; then
        READY_USER="deploy"
    elif ssh_probe "root" "echo ok" &>/dev/null; then
        READY_USER="root"
    else
        sleep 5
        waited=$((waited + 5))
        if [ $waited -ge $max_wait ]; then
            echo "ERROR: SSH not available as root or deploy after ${max_wait}s"
            exit 1
        fi
        echo "  ...waiting (${waited}s)"
    fi
done
echo "SSH ready (${READY_USER})."

# ── Phase 1: Harden ──────────────────────────────────────
if phase_done "harden"; then
    echo "=== Phase 1: Server Hardening — already done, skipping ==="
elif [ "$READY_USER" = "root" ]; then
    echo "=== Phase 1: Server Hardening ==="
    run_script root "Phase 1: Harden" "${SCRIPT_DIR}/harden.sh" "export DEBIAN_FRONTEND=noninteractive;"
    mark_done "harden"

    echo ""
    echo "Rebooting server..."
    ssh_as deploy "sudo reboot" || true
    sleep 5
    wait_for_ssh "deploy"
    READY_USER="deploy"
else
    echo "=== Phase 1: Server Hardening — deploy user exists, skipping ==="
    mark_done "harden"
fi

# ── Phase 2: Setup ──────────────────────────────────────
if phase_done "setup"; then
    echo "=== Phase 2: Application Setup — already done, skipping ==="
else
    echo ""
    echo "=== Phase 2: Application Setup ==="

    # Upload config.env to /tmp staging area (setup.sh moves it after clone)
    echo "Uploading config.env..."
    upload_file "$CONFIG_FILE" "/tmp/stoneshop-config.env" deploy 600

    # Upload backup_key if present
    if [ -f "$BACKUP_KEY" ]; then
        echo "Uploading backup_key..."
        upload_file "$BACKUP_KEY" "/tmp/stoneshop-backup_key" deploy 600
    else
        echo "No backup_key found — skipping (import will be skipped too)."
    fi

    # Run setup.sh
    run_script deploy "Phase 2: Setup" "${SCRIPT_DIR}/setup.sh" "sudo DEBIAN_FRONTEND=noninteractive"
    mark_done "setup"
fi

# ── Phase 3: Import ───────────────────────────────────
if phase_done "import"; then
    echo "=== Phase 3: Data Import — already done, skipping ==="
elif [ -f "$BACKUP_KEY" ]; then
    echo ""
    echo "=== Phase 3: Data Import ==="
    run_remote_cmd deploy "Phase 3: Import" "cd /opt/stoneshop && git pull && sudo bash infra/import.sh"
    mark_done "import"
else
    echo ""
    echo "Skipping data import (no backup_key)."
    echo "To import later:"
    echo "  scp backup_key deploy@${SERVER_IP}:/opt/stoneshop/config/backup/backup_key"
    echo "  ssh deploy@${SERVER_IP} 'cd /opt/stoneshop && sudo bash infra/import.sh'"
fi

# ── Verification ────────────────────────────────────────
echo ""
echo "=== Verification ==="
ssh_as deploy "cd /opt/stoneshop && sudo docker compose ps"

echo ""
echo "Checking HTTPS (may take a moment for TLS cert)..."
sleep 5
if curl -sSf -o /dev/null -w "%{http_code}" --connect-timeout 10 "https://${SITE_DOMAIN}" 2>/dev/null; then
    echo "  https://${SITE_DOMAIN} — OK"
else
    echo "  https://${SITE_DOMAIN} — not yet reachable (DNS propagation or TLS provisioning)"
fi

mark_done "verified"

echo ""
echo "========================================="
echo "  Deploy complete!"
echo "========================================="
echo ""
echo "  Site:    https://${SITE_DOMAIN}"
echo "  Matomo:  https://matomo.${SITE_DOMAIN}"
echo "  SSH:     ssh deploy@${SERVER_IP}"
echo ""
echo "  Secrets: ${CONFIG_FILE}"
echo "  State:   ${STATE_FILE}"
echo "  Keep both files safe!"
echo ""
