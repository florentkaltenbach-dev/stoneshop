#!/usr/bin/env bash
set -euo pipefail

# StoneShop One-Click Deploy
# Run from your laptop: ./deploy.sh <server-ip>
#
# Place next to this script (optional):
#   config.env  — generated with defaults if missing, you edit before continuing
#   backup_key  — StorageBox SSH key (import step skipped if missing)

REPO="https://raw.githubusercontent.com/florentkaltenbach-dev/stoneshop/main"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"
BACKUP_KEY="${SCRIPT_DIR}/backup_key"

# ── Parse arguments ─────────────────────────────────────
if [ $# -lt 1 ]; then
    echo "Usage: ./deploy.sh <server-ip>"
    echo ""
    echo "Optional files (place next to deploy.sh):"
    echo "  config.env  — site config + secrets (generated if missing)"
    echo "  backup_key  — StorageBox SSH key (skipped if missing)"
    exit 1
fi

SERVER_IP="$1"
SERVER_IP="${SERVER_IP#*@}"

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

SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes"
if [ -n "$SSH_KEY" ]; then
    SSH_OPTS="${SSH_OPTS} -i ${SSH_KEY}"
    echo "Using SSH key: ${SSH_KEY}"
fi

# ── Ensure config.env exists ────────────────────────────
if [ ! -f "$CONFIG_FILE" ]; then
    echo "No config.env found next to deploy.sh."
    echo "Downloading template and generating defaults..."
    curl -sSL "${REPO}/config.env.example" -o "$CONFIG_FILE"

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
ssh_as() {
    local user="$1"; shift
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "${user}@${SERVER_IP}" "$@"
}

# Streams output in real time via forced TTY. Kills if no output for 10 minutes.
ssh_stream() {
    local user="$1" phase_name="$2"; shift 2
    echo "[${phase_name}] Streaming output..."
    local rc=0
    # shellcheck disable=SC2086
    timeout --signal=KILL 600 ssh -tt $SSH_OPTS "${user}@${SERVER_IP}" "$@" || rc=$?
    if [ "$rc" -eq 137 ] || [ "$rc" -eq 124 ]; then
        echo ""
        echo "ERROR: ${phase_name} timed out (no output for 10 minutes)."
        echo "SSH into the server and check what's running:"
        echo "  ssh deploy@${SERVER_IP}"
        exit 1
    elif [ "$rc" -ne 0 ]; then
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
    # shellcheck disable=SC2086
    while ! ssh $SSH_OPTS "${user}@${SERVER_IP}" "echo ok" &>/dev/null; do
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

# ── Phase 1: Harden (skip if already done) ──────────────
echo "=== Phase 1: Server Hardening ==="

# shellcheck disable=SC2086
if ssh $SSH_OPTS "root@${SERVER_IP}" "echo ok" &>/dev/null; then
    echo "Root SSH available — running harden.sh..."
    ssh_stream root "Phase 1: Harden" "export DEBIAN_FRONTEND=noninteractive; curl -sSL '${REPO}/infra/harden.sh' | bash"

    echo ""
    echo "Rebooting server..."
    ssh_as root "reboot" || true
    sleep 10

    wait_for_ssh "deploy"
# shellcheck disable=SC2086
elif ssh $SSH_OPTS "deploy@${SERVER_IP}" "echo ok" &>/dev/null; then
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
echo "Running setup.sh..."
ssh_stream deploy "Phase 2: Setup" "sudo bash -c 'export DEBIAN_FRONTEND=noninteractive; curl -sSL \"${REPO}/infra/setup.sh\" | bash'"

# ── Phase 2.5: DNS ──────────────────────────────────────
if [ -n "${HETZNER_DNS_TOKEN:-}" ]; then
    echo ""
    echo "=== DNS Setup ==="
    ssh_stream deploy "DNS Setup" "cd /opt/stoneshop && sudo bash infra/dns.sh"
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
    ssh_stream deploy "Phase 2b: Import" "cd /opt/stoneshop && sudo bash infra/import.sh"
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
