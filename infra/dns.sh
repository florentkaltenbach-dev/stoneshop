#!/usr/bin/env bash
set -euo pipefail

# StoneShop DNS Setup — creates A records via Hetzner DNS API
# Usage: bash infra/dns.sh
#
# Reads from config.env:
#   SITE_DOMAIN    — e.g. test.stoneshop.kaltenbach.dev
#   HETZNER_DNS_TOKEN — API token from https://dns.hetzner.com/settings/api-token
#
# Auto-detects server IP via ifconfig.me
# Creates two A records: SITE_DOMAIN and matomo.SITE_DOMAIN

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: $CONFIG_FILE not found."
    exit 1
fi

source "$CONFIG_FILE"

: "${SITE_DOMAIN:?SITE_DOMAIN not set in config.env}"
: "${HETZNER_DNS_TOKEN:?HETZNER_DNS_TOKEN not set in config.env}"

API="https://dns.hetzner.com/api/v1"
AUTH="Auth-API-Token: ${HETZNER_DNS_TOKEN}"

# Auto-detect server IP
echo "Detecting server IP..."
SERVER_IP=$(curl -4 -s --connect-timeout 10 ifconfig.me)
if [ -z "$SERVER_IP" ]; then
    echo "ERROR: Could not detect server IP."
    exit 1
fi
echo "Server IP: $SERVER_IP"

# Extract zone from SITE_DOMAIN
# e.g. test.stoneshop.kaltenbach.dev → kaltenbach.dev
# We take the last two parts as the zone
ZONE=$(echo "$SITE_DOMAIN" | awk -F. '{print $(NF-1)"."$NF}')
echo "DNS zone: $ZONE"

# Get zone ID
echo "Looking up zone ID for $ZONE..."
ZONES_RESPONSE=$(curl -s -H "$AUTH" "${API}/zones")
ZONE_ID=$(echo "$ZONES_RESPONSE" | jq -r ".zones[] | select(.name == \"$ZONE\") | .id")

if [ -z "$ZONE_ID" ] || [ "$ZONE_ID" = "null" ]; then
    echo "ERROR: Zone '$ZONE' not found in your Hetzner DNS account."
    echo "Available zones:"
    echo "$ZONES_RESPONSE" | jq -r '.zones[].name'
    exit 1
fi
echo "Zone ID: $ZONE_ID"

# Record name is everything before the zone
# e.g. test.stoneshop.kaltenbach.dev with zone kaltenbach.dev → test.stoneshop
RECORD_NAME=$(echo "$SITE_DOMAIN" | sed "s/\.${ZONE}$//")
MATOMO_RECORD_NAME="matomo.${RECORD_NAME}"

echo ""
echo "Will create:"
echo "  A  ${RECORD_NAME}.${ZONE} → ${SERVER_IP}"
echo "  A  ${MATOMO_RECORD_NAME}.${ZONE} → ${SERVER_IP}"
echo ""

create_or_update_record() {
    local name="$1"
    local ip="$2"
    local ttl="${3:-300}"

    # Check if record already exists
    local existing
    existing=$(curl -s -H "$AUTH" "${API}/records?zone_id=${ZONE_ID}" | \
        jq -r ".records[] | select(.type == \"A\" and .name == \"$name\") | .id")

    if [ -n "$existing" ] && [ "$existing" != "null" ]; then
        echo "Updating existing record: $name → $ip"
        curl -s -X "PUT" "${API}/records/${existing}" \
            -H "$AUTH" \
            -H "Content-Type: application/json" \
            -d "{\"value\": \"$ip\", \"ttl\": $ttl, \"type\": \"A\", \"name\": \"$name\", \"zone_id\": \"$ZONE_ID\"}" \
            | jq -r '"  Updated: \(.record.name).\(.record.zone_id) → \(.record.value)"'
    else
        echo "Creating record: $name → $ip"
        curl -s -X "POST" "${API}/records" \
            -H "$AUTH" \
            -H "Content-Type: application/json" \
            -d "{\"value\": \"$ip\", \"ttl\": $ttl, \"type\": \"A\", \"name\": \"$name\", \"zone_id\": \"$ZONE_ID\"}" \
            | jq -r '"  Created: \(.record.name) → \(.record.value)"'
    fi
}

create_or_update_record "$RECORD_NAME" "$SERVER_IP" 300
create_or_update_record "$MATOMO_RECORD_NAME" "$SERVER_IP" 300

echo ""
echo "DNS records set. Propagation may take a few minutes."
echo "Verify with: dig +short $SITE_DOMAIN"
echo "         and: dig +short matomo.$SITE_DOMAIN"
