#!/bin/bash
# StoneShop Interactive Configuration
# Generates config.env by prompting for each value.
# Run from the project root: bash infra/configure.sh
# Safe to re-run — offers to keep existing values.

set -Eeuo pipefail

INSTALL_DIR="${1:-/opt/stoneshop}"
CONFIG_FILE="$INSTALL_DIR/config.env"
EXAMPLE_FILE="$INSTALL_DIR/config.env.example"

# ── Helpers ───────────────────────────────────────────────

gen_password() {
    openssl rand -base64 32 | tr -d '/+=' | head -c 32
}

gen_salt() {
    openssl rand -base64 48 | tr -d '/+=' | head -c 64
}

prompt() {
    local var="$1" label="$2" default="${3:-}" secret="${4:-false}"
    local current=""

    # Check for existing value in current config
    if [ -f "$CONFIG_FILE" ]; then
        current=$(grep -m1 "^${var}=" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2- || true)
    fi

    if [ -n "$current" ]; then
        if [ "$secret" = "true" ]; then
            # Show first 4 chars + masked rest so user knows what's there
            local hint="${current:0:4}..."
            read -r -p "  ${label} [${hint} — Enter to keep]: " REPLY
            REPLY="${REPLY:-$current}"
        else
            read -r -p "  ${label} [${current}]: " REPLY
            REPLY="${REPLY:-$current}"
        fi
        return
    fi

    if [ -n "$default" ]; then
        read -r -p "  ${label} [${default}]: " REPLY
        REPLY="${REPLY:-$default}"
    else
        read -r -p "  ${label}: " REPLY
    fi
}

echo ""
echo "╔══════════════════════════════════════╗"
echo "║   StoneShop Configuration Wizard     ║"
echo "╚══════════════════════════════════════╝"
echo ""

if [ -f "$CONFIG_FILE" ]; then
    echo "Existing config.env found. Existing values will be kept unless you type a replacement."
    echo ""
fi

# ── Domain ────────────────────────────────────────────────
echo "── Domain ──────────────────────────────"
prompt SITE_DOMAIN "Site domain" "stoneshop.example.com"
SITE_DOMAIN="$REPLY"

prompt TLS_EMAIL "TLS/ACME email" "admin@example.com"
TLS_EMAIL="$REPLY"

prompt OLD_DOMAIN "Old domain (for migration search-replace, leave empty to skip)" "stoneshop.kaltenbach.dev"
OLD_DOMAIN="$REPLY"
echo ""

# ── Database ──────────────────────────────────────────────
echo "── Database ──────────────────────────────"
MYSQL_ROOT_DEFAULT=$(gen_password)
prompt MYSQL_ROOT_PASSWORD "MariaDB root password" "$MYSQL_ROOT_DEFAULT" true
MYSQL_ROOT_PASSWORD="$REPLY"

prompt MYSQL_DATABASE "WordPress DB name" "stoneshop"
MYSQL_DATABASE="$REPLY"

prompt MYSQL_USER "WordPress DB user" "stoneshop"
MYSQL_USER="$REPLY"

MYSQL_PW_DEFAULT=$(gen_password)
prompt MYSQL_PASSWORD "WordPress DB password" "$MYSQL_PW_DEFAULT" true
MYSQL_PASSWORD="$REPLY"

prompt MATOMO_DATABASE_HOST "Matomo DB host" "mariadb"
MATOMO_DATABASE_HOST="$REPLY"

prompt MATOMO_DATABASE_DBNAME "Matomo DB name" "matomo"
MATOMO_DATABASE_DBNAME="$REPLY"

prompt MATOMO_DATABASE_USERNAME "Matomo DB user" "matomo"
MATOMO_DATABASE_USERNAME="$REPLY"

MATOMO_PW_DEFAULT=$(gen_password)
prompt MATOMO_DATABASE_PASSWORD "Matomo DB password" "$MATOMO_PW_DEFAULT" true
MATOMO_DATABASE_PASSWORD="$REPLY"
echo ""

# ── WordPress Salts ───────────────────────────────────────
echo "── WordPress Salts ─────────────────────"
echo "  Auto-generating 8 unique salts..."
AUTH_KEY=$(gen_salt)
SECURE_AUTH_KEY=$(gen_salt)
LOGGED_IN_KEY=$(gen_salt)
NONCE_KEY=$(gen_salt)
AUTH_SALT=$(gen_salt)
SECURE_AUTH_SALT=$(gen_salt)
LOGGED_IN_SALT=$(gen_salt)
NONCE_SALT=$(gen_salt)

# If existing config has salts, keep them
if [ -f "$CONFIG_FILE" ]; then
    existing=$(grep -m1 "^AUTH_KEY=" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2- || true)
    if [ -n "$existing" ]; then
        echo "  Keeping existing salts from config.env."
        AUTH_KEY=$(grep -m1 "^AUTH_KEY=" "$CONFIG_FILE" | cut -d= -f2-)
        SECURE_AUTH_KEY=$(grep -m1 "^SECURE_AUTH_KEY=" "$CONFIG_FILE" | cut -d= -f2-)
        LOGGED_IN_KEY=$(grep -m1 "^LOGGED_IN_KEY=" "$CONFIG_FILE" | cut -d= -f2-)
        NONCE_KEY=$(grep -m1 "^NONCE_KEY=" "$CONFIG_FILE" | cut -d= -f2-)
        AUTH_SALT=$(grep -m1 "^AUTH_SALT=" "$CONFIG_FILE" | cut -d= -f2-)
        SECURE_AUTH_SALT=$(grep -m1 "^SECURE_AUTH_SALT=" "$CONFIG_FILE" | cut -d= -f2-)
        LOGGED_IN_SALT=$(grep -m1 "^LOGGED_IN_SALT=" "$CONFIG_FILE" | cut -d= -f2-)
        NONCE_SALT=$(grep -m1 "^NONCE_SALT=" "$CONFIG_FILE" | cut -d= -f2-)
    else
        echo "  Generated fresh salts."
    fi
else
    echo "  Generated fresh salts."
fi
echo ""

# ── Restic Backup ─────────────────────────────────────────
echo "── Restic Backup ─────────────────────────"
prompt RESTIC_REPOSITORY "Restic repository" "sftp:storagebox:backups/stoneshop"
RESTIC_REPOSITORY="$REPLY"

RESTIC_PW_DEFAULT=$(gen_password)
prompt RESTIC_PASSWORD "Restic password" "$RESTIC_PW_DEFAULT" true
RESTIC_PASSWORD="$REPLY"
echo ""

# ── StorageBox ────────────────────────────────────────────
echo "── StorageBox (backup target) ─────────────"
prompt STORAGEBOX_HOST "StorageBox hostname" "uXXXXXX.your-storagebox.de"
STORAGEBOX_HOST="$REPLY"

prompt STORAGEBOX_USER "StorageBox user" "uXXXXXX"
STORAGEBOX_USER="$REPLY"

prompt STORAGEBOX_PORT "StorageBox SSH port" "23"
STORAGEBOX_PORT="$REPLY"
echo ""

# ── CrowdSec ─────────────────────────────────────────────
echo "── CrowdSec (optional) ───────────────────"
prompt CROWDSEC_ENROLL_KEY "CrowdSec enrollment key (leave empty to skip)" ""
CROWDSEC_ENROLL_KEY="$REPLY"
echo ""

# ── Write config.env ──────────────────────────────────────
cat > "$CONFIG_FILE" <<ENVEOF
# StoneShop Configuration
# Generated by infra/configure.sh on $(date -Iseconds)
# NEVER commit this file — it contains secrets.

# ── Domain ──────────────────────────────────────────────
SITE_DOMAIN=${SITE_DOMAIN}
TLS_EMAIL=${TLS_EMAIL}

# Migration only: set to the previous domain for wp search-replace.
# Remove or leave empty after migration is complete.
OLD_DOMAIN=${OLD_DOMAIN}

# ── Database ────────────────────────────────────────────
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
MYSQL_DATABASE=${MYSQL_DATABASE}
MYSQL_USER=${MYSQL_USER}
MYSQL_PASSWORD=${MYSQL_PASSWORD}

MATOMO_DATABASE_HOST=${MATOMO_DATABASE_HOST}
MATOMO_DATABASE_DBNAME=${MATOMO_DATABASE_DBNAME}
MATOMO_DATABASE_USERNAME=${MATOMO_DATABASE_USERNAME}
MATOMO_DATABASE_PASSWORD=${MATOMO_DATABASE_PASSWORD}

# ── WordPress salts ─────────────────────────────────────
AUTH_KEY=${AUTH_KEY}
SECURE_AUTH_KEY=${SECURE_AUTH_KEY}
LOGGED_IN_KEY=${LOGGED_IN_KEY}
NONCE_KEY=${NONCE_KEY}
AUTH_SALT=${AUTH_SALT}
SECURE_AUTH_SALT=${SECURE_AUTH_SALT}
LOGGED_IN_SALT=${LOGGED_IN_SALT}
NONCE_SALT=${NONCE_SALT}

# ── Restic backup ───────────────────────────────────────
RESTIC_REPOSITORY=${RESTIC_REPOSITORY}
RESTIC_PASSWORD=${RESTIC_PASSWORD}

# ── StorageBox (backup target) ────────────────────────
STORAGEBOX_HOST=${STORAGEBOX_HOST}
STORAGEBOX_USER=${STORAGEBOX_USER}
STORAGEBOX_PORT=${STORAGEBOX_PORT}

# ── CrowdSec (optional) ────────────────────────────────
CROWDSEC_ENROLL_KEY=${CROWDSEC_ENROLL_KEY}
ENVEOF

chmod 0600 "$CONFIG_FILE"
echo "✓ config.env written to ${CONFIG_FILE}"
echo ""

# Create .env symlink if it doesn't exist
if [ ! -L "$INSTALL_DIR/.env" ]; then
    ln -sf config.env "$INSTALL_DIR/.env"
    echo "✓ .env symlink created → config.env"
fi

echo ""
echo "Done. Review with: cat ${CONFIG_FILE}"
echo "Then run: sudo bash infra/setup.sh"
