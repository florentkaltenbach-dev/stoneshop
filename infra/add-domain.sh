#!/usr/bin/env bash
set -euo pipefail

# Interactive helper to add a new domain to Dockbase.
# Appends to config/domains.conf, regenerates Caddyfile, reloads Caddy.
# Usage: bash infra/add-domain.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DOMAINS_FILE="${REPO_DIR}/config/domains.conf"

echo "=== Add Domain to Dockbase ==="
echo ""

read -r -p "Domain (e.g., example.com): " DOMAIN
if [ -z "$DOMAIN" ]; then
    echo "ERROR: Domain cannot be empty." >&2
    exit 1
fi

# Check if already exists
if grep -q "^${DOMAIN}[[:space:]]" "$DOMAINS_FILE" 2>/dev/null; then
    echo "Domain ${DOMAIN} already exists in domains.conf."
    exit 0
fi

echo ""
echo "Available backends:"
echo "  shop        — WooCommerce (reverse proxy to FrankenPHP)"
echo "  website     — Static website (file server)"
echo "  mailweb     — Mailcow web UI (reverse proxy)"
echo "  matomo-shop — Matomo for shop"
echo "  matomo-web  — Matomo for website"
echo ""
read -r -p "Backend: " BACKEND

case "$BACKEND" in
    shop|website|mailweb|matomo-shop|matomo-web) ;;
    *)
        echo "ERROR: Unknown backend '${BACKEND}'." >&2
        exit 1
        ;;
esac

# Append to domains.conf
printf "%-40s %s\n" "$DOMAIN" "$BACKEND" >> "$DOMAINS_FILE"
echo "Added: ${DOMAIN} -> ${BACKEND}"

# Also add www variant?
read -r -p "Also add www.${DOMAIN}? [Y/n] " ADD_WWW
case "${ADD_WWW:-Y}" in
    [Nn]*) ;;
    *)
        if ! grep -q "^www\.${DOMAIN}[[:space:]]" "$DOMAINS_FILE" 2>/dev/null; then
            printf "%-40s %s\n" "www.${DOMAIN}" "$BACKEND" >> "$DOMAINS_FILE"
            echo "Added: www.${DOMAIN} -> ${BACKEND}"
        fi
        ;;
esac

# Regenerate Caddyfile
echo ""
echo "Regenerating Caddyfile..."
bash "${SCRIPT_DIR}/generate-caddyfile.sh"

# Reload Caddy
echo "Reloading Caddy..."
docker exec dockbase_caddy caddy reload --config /etc/caddy/Caddyfile 2>/dev/null || {
    echo "WARNING: Could not reload Caddy. Reload manually:"
    echo "  docker exec dockbase_caddy caddy reload --config /etc/caddy/Caddyfile"
}

echo ""
echo "Done. Run 'bash infra/dns-records.sh' to see required DNS records."
