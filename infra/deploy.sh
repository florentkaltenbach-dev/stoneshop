#!/usr/bin/env bash
set -euo pipefail

# StoneShop One-Click Deploy
# Run from your laptop: ./deploy.sh root@<server-ip>
#
# If config.env exists next to this script, it gets uploaded.
# If not, a default is generated from config.env.example for you to edit.

REPO="https://raw.githubusercontent.com/florentkaltenbach-dev/stoneshop/main"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"
BACKUP_KEY="${SCRIPT_DIR}/backup_key"

# ── Parse arguments ─────────────────────────────────────
if [ $# -lt 1 ]; then
    echo "Usage: ./deploy.sh root@<server-ip>"
    echo ""
    echo "Optional files (place next to deploy.sh):"
    echo "  config.env  — site config + secrets (generated if missing)"
    echo "  backup_key  — StorageBox SSH key (skipped if missing)"
    exit 1
fi

TARGET="$1"
SERVER_IP="${TARGET#*@}"

# ── Ensure config.env exists ────────────────────────────
if [ ! -f "$CONFIG_FILE" ]; then
    echo "No config.env found next to deploy.sh."
    echo "Downloading template and generating defaults..."
    curl -sSL "${REPO}/config.env.example" -o "$CONFIG_FILE"

    # Generate random passwords and salts
    generate_password() { openssl rand -base64 24 | tr -d '/+=' | head -c 32; }

    # Replace placeholder passwords
    sed -i.bak "s/^MYSQL_ROOT_PASSWORD=changeme$/MYSQL_ROOT_PASSWORD=$(generate_password)/" "$CONFIG_FILE"
    sed -i.bak "s/^MYSQL_PASSWORD=changeme$/MYSQL_PASSWORD=$(generate_password)/" "$CONFIG_FILE"
    sed -i.bak "s/^MATOMO_DATABASE_PASSWORD=changeme$/MATOMO_DATABASE_PASSWORD=$(generate_password)/" "$CONFIG_FILE"
    sed -i.bak "s/^RESTIC_PASSWORD=changeme$/RESTIC_PASSWORD=$(generate_password)/" "$CONFIG_FILE"

    # Generate WP salts
    for key in AUTH_KEY SECURE_AUTH_KEY LOGGED_IN_KEY NONCE_KEY AUTH_SALT SECURE_AUTH_SALT LOGGED_IN_SALT NONCE_SALT; do
        sed -i.bak "s/^${key}=$/${key}=$(openssl rand -base64 48 | tr -d '/+=' | head -c 64)/" "$CONFIG_FILE"
    done

    rm -f "${CONFIG_FILE}.bak"

    echo ""
    echo "Generated: ${CONFIG_FILE}"
    echo ""
    echo ">>> EDIT THIS FILE NOW <<<"
    echo "At minimum, set:"
    echo "  SITE_DOMAIN    — your actual domain"
    echo "  TLS_EMAIL      — your email for Let's Encrypt"
    echo "  OLD_DOMAIN     — previous domain (for migration)"
    echo "  HETZNER_DNS_TOKEN — if you want automatic DNS setup"
    echo ""
    read -r -p "Press Enter when ready (or Ctrl+C to abort)..."

    # Re-read in case they edited
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

echo ""
echo "=== StoneShop Deploy ==="
echo "Server:  ${SERVER_IP}"
echo "Config:  ${CONFIG_FILE}"
echo ""

# Validate config.env has required fields
source "$CONFIG_FILE"
: "${SITE_DOMAIN:?SITE_DOMAIN not set in config.env}"
: "${TLS_EMAIL:?TLS_EMAIL not set in config.env}"

# ── Helper: SSH with common options ─────────────────────
ssh_root() { ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "root@${SERVER_IP}" "$@"; }
ssh_deploy() { ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "deploy@${SERVER_IP}" "$@"; }

wait_for_ssh() {
    local user="$1"
    local max_wait=120
    local waited=0
    echo "Waiting for SSH as ${user}@${SERVER_IP}..."
    while ! ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o BatchMode=yes "${user}@${SERVER_IP}" "echo ok" &>/dev/null; do
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

# ── Phase 1: Harden ────────────────────────────────────
echo ""
echo "=== Phase 1: Server Hardening ==="
ssh_root "curl -sSL '${REPO}/infra/harden.sh' | bash"

echo ""
echo "Rebooting server..."
ssh_root "reboot" || true
sleep 10

wait_for_ssh "deploy"

# ── Phase 2: Setup ──────────────────────────────────────
echo ""
echo "=== Phase 2: Application Setup ==="

# Upload config.env
echo "Uploading config.env..."
ssh_deploy "sudo mkdir -p /opt/stoneshop"
scp -o StrictHostKeyChecking=accept-new "$CONFIG_FILE" "deploy@${SERVER_IP}:/tmp/config.env"
ssh_deploy "sudo mv /tmp/config.env /opt/stoneshop/config.env && sudo chown deploy:project /opt/stoneshop/config.env && sudo chmod 600 /opt/stoneshop/config.env"

# Upload backup_key if present
if [ -f "$BACKUP_KEY" ]; then
    echo "Uploading backup_key..."
    ssh_deploy "sudo mkdir -p /opt/stoneshop/config/backup"
    scp -o StrictHostKeyChecking=accept-new "$BACKUP_KEY" "deploy@${SERVER_IP}:/tmp/backup_key"
    ssh_deploy "sudo mv /tmp/backup_key /opt/stoneshop/config/backup/backup_key && sudo chmod 600 /opt/stoneshop/config/backup/backup_key"
else
    echo "No backup_key found next to deploy.sh — skipping (import.sh will need it later)."
fi

# Run setup.sh
ssh_deploy "sudo bash -c 'curl -sSL \"${REPO}/infra/setup.sh\" | bash'"

# ── Phase 2.5: DNS ──────────────────────────────────────
if [ -n "${HETZNER_DNS_TOKEN:-}" ]; then
    echo ""
    echo "=== DNS Setup ==="
    ssh_deploy "cd /opt/stoneshop && sudo bash infra/dns.sh"
else
    echo ""
    echo "Skipping DNS setup (no HETZNER_DNS_TOKEN in config.env)."
    echo "Create A records manually:"
    echo "  ${SITE_DOMAIN} → ${SERVER_IP}"
    echo "  matomo.${SITE_DOMAIN} → ${SERVER_IP}"
fi

# ── Phase 2b: Import ───────────────────────────────────
if [ -f "$BACKUP_KEY" ]; then
    echo ""
    echo "=== Phase 2b: Data Import ==="
    ssh_deploy "cd /opt/stoneshop && sudo bash infra/import.sh"
else
    echo ""
    echo "Skipping data import (no backup_key). Run manually after placing it:"
    echo "  ssh deploy@${SERVER_IP}"
    echo "  cd /opt/stoneshop && sudo bash infra/import.sh"
fi

# ── Verification ────────────────────────────────────────
echo ""
echo "=== Verification ==="
echo "Checking services..."
ssh_deploy "cd /opt/stoneshop && sudo docker compose ps"

echo ""
echo "Checking HTTPS..."
if curl -sSf -o /dev/null -w "%{http_code}" --connect-timeout 10 "https://${SITE_DOMAIN}" 2>/dev/null; then
    echo "  https://${SITE_DOMAIN} — OK"
else
    echo "  https://${SITE_DOMAIN} — not yet reachable (DNS may still be propagating)"
fi

echo ""
echo "=== Deploy complete ==="
echo ""
echo "Your site: https://${SITE_DOMAIN}"
echo "Matomo:    https://matomo.${SITE_DOMAIN}"
echo "SSH:       ssh deploy@${SERVER_IP}"
echo ""
echo "config.env saved locally at: ${CONFIG_FILE}"
echo "Keep this file safe — it contains all your secrets."
