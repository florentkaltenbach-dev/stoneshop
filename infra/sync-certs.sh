#!/usr/bin/env bash
set -euo pipefail

# Sync TLS certificates from shared Caddy into Mailcow
# Run after Caddy has obtained certs for MAIL_HOSTNAME.
# Can be run periodically (e.g., weekly cron) to keep certs fresh.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_root
load_config
require_var MAIL_HOSTNAME

MAILCOW_DIR="/opt/mailcow"
MAILCOW_SSL_DIR="${MAILCOW_DIR}/data/assets/ssl"

# Caddy stores certs in its data volume
# The exact path depends on the ACME provider; default is Let's Encrypt
# Try both possible volume names (with and without compose project prefix)
CADDY_DATA_DIR=""
for vol_name in dockbase_caddy_shared_data caddy_shared_data; do
    CADDY_DATA_DIR=$(docker volume inspect "$vol_name" --format '{{ .Mountpoint }}' 2>/dev/null || echo "")
    [ -n "$CADDY_DATA_DIR" ] && break
done

if [ -z "$CADDY_DATA_DIR" ]; then
    log_error "Could not find Caddy data volume. Is shared Caddy running?"
    log_error "Looked for: dockbase_caddy_shared_data, caddy_shared_data"
    exit 1
fi

# Caddy stores certs at: <data>/caddy/certificates/acme-v02.api.letsencrypt.org-directory/<domain>/
CERT_DIR="${CADDY_DATA_DIR}/caddy/certificates/acme-v02.api.letsencrypt.org-directory/${MAIL_HOSTNAME}"

if [ ! -d "$CERT_DIR" ]; then
    # Try the ZeroSSL path as fallback
    CERT_DIR="${CADDY_DATA_DIR}/caddy/certificates/acme.zerossl.com-v2-DV90/${MAIL_HOSTNAME}"
fi

if [ ! -d "$CERT_DIR" ]; then
    log_error "No certificates found for ${MAIL_HOSTNAME} in Caddy data volume."
    log_error "Ensure shared Caddy is running and has obtained certs."
    log_error "Looked in: ${CADDY_DATA_DIR}/caddy/certificates/*/${MAIL_HOSTNAME}/"
    exit 1
fi

CERT_FILE="${CERT_DIR}/${MAIL_HOSTNAME}.crt"
KEY_FILE="${CERT_DIR}/${MAIL_HOSTNAME}.key"

if [ ! -f "$CERT_FILE" ] || [ ! -f "$KEY_FILE" ]; then
    log_error "Certificate or key file not found:"
    log_error "  cert: ${CERT_FILE}"
    log_error "  key:  ${KEY_FILE}"
    exit 1
fi

# ── Copy into Mailcow ──────────────────────────────────
mkdir -p "$MAILCOW_SSL_DIR"
cp "$CERT_FILE" "${MAILCOW_SSL_DIR}/cert.pem"
cp "$KEY_FILE" "${MAILCOW_SSL_DIR}/key.pem"
chmod 0644 "${MAILCOW_SSL_DIR}/cert.pem"
chmod 0600 "${MAILCOW_SSL_DIR}/key.pem"

log_info "Certificates synced to ${MAILCOW_SSL_DIR}"

# ── Restart Mailcow TLS containers ─────────────────────
log_info "Restarting Mailcow TLS-dependent containers..."
cd "${MAILCOW_DIR}"
docker compose restart postfix-mailcow dovecot-mailcow nginx-mailcow 2>/dev/null || {
    log_warn "Some Mailcow containers could not be restarted. Check manually."
}

log_info "Certificate sync complete."
