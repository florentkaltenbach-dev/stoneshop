#!/usr/bin/env bash
set -euo pipefail

# StoneShop One-Click Deploy
# Run from your laptop: ./deploy.sh <server-ip>
#
# Place next to this script (optional):
#   config.env  — generated with defaults if missing, you edit before continuing
#   backup_key  — StorageBox SSH key (import step skipped if missing)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"
BACKUP_KEY="${SCRIPT_DIR}/backup_key"

# ── Parse arguments ─────────────────────────────────────
FRESH=false
for arg in "$@"; do
    case "$arg" in
        --fresh) FRESH=true ;;
    esac
done

# Strip flags to get positional args
POSITIONAL=()
for arg in "$@"; do
    case "$arg" in
        --fresh) ;;
        *) POSITIONAL+=("$arg") ;;
    esac
done

if [ ${#POSITIONAL[@]} -lt 1 ]; then
    echo "Usage: ./deploy.sh [--fresh] <server-ip>"
    echo ""
    echo "Options:"
    echo "  --fresh     Clear known_hosts for this IP (use after server rebuild)"
    echo ""
    echo "Optional files (place next to deploy.sh):"
    echo "  config.env  — site config + secrets (generated if missing)"
    echo "  backup_key  — StorageBox SSH key (skipped if missing)"
    exit 1
fi

SERVER_IP="${POSITIONAL[0]}"
SERVER_IP="${SERVER_IP#*@}"

if [ "$FRESH" = true ]; then
    echo "Clearing known_hosts for ${SERVER_IP} (--fresh)..."
    ssh-keygen -R "$SERVER_IP" 2>/dev/null || true
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

# BatchMode for short probe commands only
SSH_PROBE="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes"
# No BatchMode for long-running commands (avoids TTY/buffering issues in WSL)
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

    sed -i.bak "s/^MYSQL_ROOT_PASSWORD=changeme$/MYSQL_ROOT_PASSWORD=$(generate_password)/" "$CONFIG_FILE"
    sed -i.bak "s/^MYSQL_PASSWORD=changeme$/MYSQL_PASSWORD=$(generate_password)/" "$CONFIG_FILE"
    sed -i.bak "s/^MATOMO_DATABASE_PASSWORD=changeme$/MATOMO_DATABASE_PASSWORD=$(generate_password)/" "$CONFIG_FILE"
    sed -i.bak "s/^RESTIC_PASSWORD=changeme$/RESTIC_PASSWORD=$(generate_password)/" "$CONFIG_FILE"

    for key in AUTH_KEY SECURE_AUTH_KEY LOGGED_IN_KEY NONCE_KEY AUTH_SALT SECURE_AUTH_SALT LOGGED_IN_SALT NONCE_SALT; do
        sed -i.bak "s/^${key}=$/${key}=$(openssl rand -base64 48 | tr -d '/+=' | head -c 64)/" "$CONFIG_FILE"
    done

    rm -f "${CONFIG_FILE}.bak"

    echo ""
    echo "Generated: ${CONFIG_FILE}"
    echo ""
    echo ">>> EDIT THIS FILE NOW <<<"
    echo "At minimum, set:"
    echo "  SITE_DOMAIN       — your actual domain"
    echo "  TLS_EMAIL         — your email for Let's Encrypt"
    echo "  OLD_DOMAIN        — previous domain (for migration)"
    echo "  HETZNER_DNS_TOKEN — for automatic DNS setup (optional)"
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

# Short probe commands (BatchMode, quiet)
ssh_probe() {
    local user="$1"; shift
    # shellcheck disable=SC2086
    ssh $SSH_PROBE "${user}@${SERVER_IP}" "$@"
}

# Short commands that need output
ssh_as() {
    local user="$1"; shift
    # shellcheck disable=SC2086
    ssh $SSH_RUN "${user}@${SERVER_IP}" "$@"
}

# Upload a local script to the server, then execute it (streams output live)
run_script() {
    local user="$1" phase_name="$2" local_script="$3"
    shift 3
    local env_prefix="${*:-}"

    echo "[${phase_name}] Uploading ${local_script}..."
    local scp_opts="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
    [ -n "$SSH_KEY" ] && scp_opts="${scp_opts} -i ${SSH_KEY}"
    # shellcheck disable=SC2086
    scp $scp_opts "$local_script" "${user}@${SERVER_IP}:/tmp/_phase_script.sh"

    echo "[${phase_name}] Running..."
    local rc=0
    # shellcheck disable=SC2086
    ssh $SSH_RUN "${user}@${SERVER_IP}" "${env_prefix:+$env_prefix }bash /tmp/_phase_script.sh" || rc=$?

    if [ "$rc" -ne 0 ]; then
        echo ""
        echo "ERROR: ${phase_name} failed (exit code ${rc})."
        echo "SSH into the server to investigate:"
        echo "  ssh deploy@${SERVER_IP}"
        exit "$rc"
    fi
}

# Run a command on the server (streams output live)
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
    local max_wait=120
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
    local src="$1" dest="$2" mode="${3:-644}"
    local scp_opts="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
    [ -n "$SSH_KEY" ] && scp_opts="${scp_opts} -i ${SSH_KEY}"
    # shellcheck disable=SC2086
    scp $scp_opts "$src" "deploy@${SERVER_IP}:/tmp/_upload"
    ssh_as deploy "sudo mv /tmp/_upload ${dest} && sudo chmod ${mode} ${dest}"
}

# ── Wait for server to be reachable ──────────────────────
echo "Waiting for SSH on ${SERVER_IP}..."
READY_USER=""
max_wait=120
waited=0
while [ -z "$READY_USER" ]; do
    if ssh_probe "root" "echo ok" &>/dev/null; then
        READY_USER="root"
    elif ssh_probe "deploy" "echo ok" &>/dev/null; then
        READY_USER="deploy"
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

# ── Phase 1: Harden (skip if already done) ──────────────
echo "=== Phase 1: Server Hardening ==="

if [ "$READY_USER" = "root" ]; then
    echo "Root SSH available — running harden.sh..."
    run_script root "Phase 1: Harden" "${SCRIPT_DIR}/harden.sh" "export DEBIAN_FRONTEND=noninteractive;"

    echo ""
    echo "Rebooting server..."
    ssh_as root "reboot" || true
    sleep 10

    wait_for_ssh "deploy"
elif ssh_probe "deploy" "echo ok" &>/dev/null; then
    echo "Root SSH disabled, deploy SSH works — Phase 1 already done, skipping."
else
    echo "ERROR: Cannot SSH as root or deploy to ${SERVER_IP}"
    echo "Check that your SSH key is set up and the server is reachable."
    exit 1
fi

# ── Phase 2: Setup ──────────────────────────────────────
echo ""
echo "=== Phase 2: Application Setup ==="

# Clean up any leftover state from failed runs
echo "Preparing /opt/stoneshop..."
ssh_as deploy "sudo rm -rf /opt/stoneshop; sudo mkdir -p /opt/stoneshop; sudo chown deploy:project /opt/stoneshop"

# Upload config.env before setup.sh runs
echo "Uploading config.env..."
upload_file "$CONFIG_FILE" "/opt/stoneshop/config.env" 600

# Upload backup_key if present
if [ -f "$BACKUP_KEY" ]; then
    echo "Uploading backup_key..."
    ssh_as deploy "sudo mkdir -p /opt/stoneshop/config/backup"
    upload_file "$BACKUP_KEY" "/opt/stoneshop/config/backup/backup_key" 600
else
    echo "No backup_key found — skipping (import will be skipped too)."
fi

# Run setup.sh
run_script deploy "Phase 2: Setup" "${SCRIPT_DIR}/setup.sh" "sudo DEBIAN_FRONTEND=noninteractive"

# ── Phase 2.5: DNS ──────────────────────────────────────
if [ -n "${HETZNER_DNS_TOKEN:-}" ]; then
    echo ""
    echo "=== DNS Setup ==="
    run_remote_cmd deploy "DNS Setup" "cd /opt/stoneshop && sudo bash infra/dns.sh"
    echo "Waiting 30s for DNS propagation..."
    sleep 30
else
    echo ""
    echo "Skipping DNS (no HETZNER_DNS_TOKEN). Create A records manually:"
    echo "  ${SITE_DOMAIN} → ${SERVER_IP}"
    echo "  matomo.${SITE_DOMAIN} → ${SERVER_IP}"
fi

# ── Phase 2b: Import ───────────────────────────────────
if [ -f "$BACKUP_KEY" ]; then
    echo ""
    echo "=== Phase 2b: Data Import ==="
    run_remote_cmd deploy "Phase 2b: Import" "cd /opt/stoneshop && sudo bash infra/import.sh"
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
echo "  Keep this file safe!"
echo ""
