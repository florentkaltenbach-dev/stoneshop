#!/usr/bin/env bash
set -euo pipefail

# Dockbase Phase 5: Mailcow
# Clones, configures, and starts Mailcow behind the shared Caddy reverse proxy.
# Optionally automates domain/mailbox creation via Mailcow API.
# Run as root on the server.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_root
load_config
require_var MAIL_HOSTNAME

MAILCOW_DIR="/opt/mailcow"
MAIL_DOMAINS_FILE="${INSTALL_DIR}/config/mail-domains.conf"

log_info "=== Setting up Mailcow ==="

# ── Clone Mailcow ───────────────────────────────────────
if [ -d "${MAILCOW_DIR}/docker-compose.yml" ] || [ -d "${MAILCOW_DIR}/compose.yaml" ]; then
    log_info "Mailcow already cloned at ${MAILCOW_DIR}, updating..."
    cd "${MAILCOW_DIR}"
    git pull || log_warn "Git pull failed — continuing with existing version"
else
    log_info "Cloning mailcow-dockerized to ${MAILCOW_DIR}..."
    git clone https://github.com/mailcow/mailcow-dockerized.git "${MAILCOW_DIR}"
fi

cd "${MAILCOW_DIR}"

# ── Generate mailcow.conf ──────────────────────────────
log_info "Generating mailcow.conf..."

# Use Mailcow's own generate_config if available, then override
if [ -f "${MAILCOW_DIR}/generate_config.sh" ] && [ ! -f "${MAILCOW_DIR}/mailcow.conf" ]; then
    log_info "Running Mailcow generate_config.sh..."
    MAILCOW_HOSTNAME="${MAIL_HOSTNAME}" \
    MAILCOW_TZ="Europe/Berlin" \
    bash "${MAILCOW_DIR}/generate_config.sh" || true
fi

# Apply our required overrides (idempotent)
CONF="${MAILCOW_DIR}/mailcow.conf"
if [ -f "$CONF" ]; then
    # Override settings in existing conf
    sed -i "s|^MAILCOW_HOSTNAME=.*|MAILCOW_HOSTNAME=${MAIL_HOSTNAME}|" "$CONF"
    sed -i "s|^HTTP_BIND=.*|HTTP_BIND=127.0.0.1|" "$CONF"
    sed -i "s|^HTTP_PORT=.*|HTTP_PORT=8880|" "$CONF"
    sed -i "s|^HTTPS_BIND=.*|HTTPS_BIND=127.0.0.1|" "$CONF"
    sed -i "s|^HTTPS_PORT=.*|HTTPS_PORT=8443|" "$CONF"
    sed -i "s|^SKIP_LETS_ENCRYPT=.*|SKIP_LETS_ENCRYPT=y|" "$CONF"

    # Add SKIP_SOLR if not present (saves RAM on 8GB VPS)
    if ! grep -q "^SKIP_SOLR=" "$CONF"; then
        echo "SKIP_SOLR=y" >> "$CONF"
    else
        sed -i "s|^SKIP_SOLR=.*|SKIP_SOLR=y|" "$CONF"
    fi
else
    # Create minimal conf
    cat > "$CONF" <<MCEOF
MAILCOW_HOSTNAME=${MAIL_HOSTNAME}
DBNAME=mailcow
DBUSER=mailcow
DBPASS=$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)
DBROOT=$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)
HTTP_BIND=127.0.0.1
HTTP_PORT=8880
HTTPS_BIND=127.0.0.1
HTTPS_PORT=8443
SMTP_PORT=25
SMTPS_PORT=465
SUBMISSION_PORT=587
IMAP_PORT=143
IMAPS_PORT=993
SIEVE_PORT=4190
TZ=Europe/Berlin
SKIP_LETS_ENCRYPT=y
SKIP_SOLR=y
COMPOSE_PROJECT_NAME=mailcowdockerized
MCEOF
fi

log_info "mailcow.conf configured (web on 127.0.0.1:8880/8443, TLS skipped)."

# ── Start Mailcow ──────────────────────────────────────
log_info "Starting Mailcow..."
cd "${MAILCOW_DIR}"
docker compose up -d

log_info "Waiting for Mailcow to become ready (this may take a few minutes)..."
sleep 30

# Wait for the nginx container (web frontend)
local_wait=0
while ! docker exec "$(docker ps -qf name=nginx-mailcow)" nginx -t &>/dev/null 2>&1; do
    sleep 10
    local_wait=$((local_wait + 10))
    if [ "$local_wait" -ge 300 ]; then
        log_warn "Mailcow nginx not ready after 5 minutes — continuing anyway"
        break
    fi
done

# ── API automation (if mail-domains.conf exists) ────────
if [ ! -f "$MAIL_DOMAINS_FILE" ] || [ ! -s "$MAIL_DOMAINS_FILE" ]; then
    log_info "No mail-domains.conf found or file is empty."
    log_info "Add domains via Mailcow UI at https://${MAIL_HOSTNAME}"
    log_info "Or populate config/mail-domains.conf and re-run."
else
    log_info "Attempting API-based domain/mailbox setup..."

    # Get or create API key
    API_KEY="${MAILCOW_API_KEY:-}"

    if [ -z "$API_KEY" ]; then
        log_info "No MAILCOW_API_KEY in config.env — attempting to retrieve from Mailcow DB..."
        MAILCOW_DBPASS=$(grep "^DBPASS=" "$CONF" | cut -d= -f2-)
        API_KEY=$(docker exec "$(docker ps -qf name=mysql-mailcow)" \
            mysql -u mailcow -p"${MAILCOW_DBPASS}" mailcow \
            -se "SELECT api_key FROM api WHERE active='1' AND allow_from='' LIMIT 1" 2>/dev/null || true)

        if [ -z "$API_KEY" ]; then
            log_info "No API key found — creating one..."
            API_KEY=$(openssl rand -hex 32)
            docker exec "$(docker ps -qf name=mysql-mailcow)" \
                mysql -u mailcow -p"${MAILCOW_DBPASS}" mailcow \
                -e "INSERT INTO api (api_key, active, allow_from, created, modified, access) VALUES ('${API_KEY}', '1', '', NOW(), NOW(), 'rw') ON DUPLICATE KEY UPDATE active='1';" 2>/dev/null || {
                    log_warn "Could not create API key in Mailcow DB."
                    API_KEY=""
                }
        fi

        # Save to config.env for future runs
        if [ -n "$API_KEY" ]; then
            if grep -q "^MAILCOW_API_KEY=" "${CONFIG_FILE}"; then
                sed -i "s|^MAILCOW_API_KEY=.*|MAILCOW_API_KEY=${API_KEY}|" "${CONFIG_FILE}"
            else
                echo "MAILCOW_API_KEY=${API_KEY}" >> "${CONFIG_FILE}"
            fi
            log_info "API key saved to config.env."
        fi
    fi

    if [ -z "$API_KEY" ]; then
        log_warn "Could not obtain Mailcow API key."
        log_warn "Manual setup required at https://${MAIL_HOSTNAME}"
    else
        MAILCOW_API="http://127.0.0.1:8880/api/v1"
        AUTH_HEADER="X-API-Key: ${API_KEY}"
        PASSWORDS_FILE="${MAILCOW_DIR}/initial-passwords.txt"
        > "$PASSWORDS_FILE"
        chmod 0600 "$PASSWORDS_FILE"

        current_domain=""
        while IFS= read -r line; do
            # Skip blanks and comments
            [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

            # Domain header: [domain.tld]
            if [[ "$line" =~ ^\[(.+)\]$ ]]; then
                current_domain="${BASH_REMATCH[1]}"
                log_info "Adding domain: ${current_domain}"

                # Add domain (idempotent — 409 if exists)
                http_code=$(curl -sS -o /dev/null -w "%{http_code}" \
                    -X POST "${MAILCOW_API}/add/domain" \
                    -H "${AUTH_HEADER}" \
                    -H "Content-Type: application/json" \
                    -d "{\"domain\":\"${current_domain}\",\"active\":\"1\",\"restart_sogo\":\"1\"}" 2>/dev/null || echo "000")

                if [ "$http_code" = "200" ] || [ "$http_code" = "409" ]; then
                    log_info "  Domain ${current_domain}: OK (${http_code})"
                else
                    log_warn "  Domain ${current_domain}: unexpected response ${http_code}"
                fi

                # Generate DKIM
                curl -sS -o /dev/null \
                    -X POST "${MAILCOW_API}/add/dkim" \
                    -H "${AUTH_HEADER}" \
                    -H "Content-Type: application/json" \
                    -d "{\"domains\":\"${current_domain}\",\"dkim_selector\":\"dkim\",\"key_size\":2048}" 2>/dev/null || true

                continue
            fi

            # Mailbox line: localpart  Display Name
            if [ -n "$current_domain" ]; then
                local_part=$(echo "$line" | awk '{print $1}')
                display_name=$(echo "$line" | sed 's/^[^ ]* *//')
                [ -z "$local_part" ] && continue

                mailbox_pw=$(openssl rand -base64 18 | tr -d '/+=' | head -c 16)
                email="${local_part}@${current_domain}"

                log_info "  Adding mailbox: ${email}"

                http_code=$(curl -sS -o /dev/null -w "%{http_code}" \
                    -X POST "${MAILCOW_API}/add/mailbox" \
                    -H "${AUTH_HEADER}" \
                    -H "Content-Type: application/json" \
                    -d "{\"local_part\":\"${local_part}\",\"domain\":\"${current_domain}\",\"name\":\"${display_name}\",\"password\":\"${mailbox_pw}\",\"password2\":\"${mailbox_pw}\",\"active\":\"1\"}" 2>/dev/null || echo "000")

                if [ "$http_code" = "200" ]; then
                    echo "${email}  ${mailbox_pw}" >> "$PASSWORDS_FILE"
                    log_info "    Created: ${email}"
                elif [ "$http_code" = "409" ]; then
                    log_info "    Already exists: ${email}"
                else
                    log_warn "    Unexpected response ${http_code} for ${email}"
                fi
            fi
        done < "$MAIL_DOMAINS_FILE"

        if [ -s "$PASSWORDS_FILE" ]; then
            chown deploy:deploy "$PASSWORDS_FILE"
            log_info ""
            log_info "Initial mailbox passwords saved to: ${PASSWORDS_FILE}"
            log_info "Change them on first login!"
        fi
    fi
fi

# ── Summary ────────────────────────────────────────────
log_info ""
log_info "=== Mailcow setup complete ==="
log_info "Web UI:  https://${MAIL_HOSTNAME} (proxied by shared Caddy)"
log_info "Admin:   https://${MAIL_HOSTNAME} (default login: admin / moohoo)"
log_info ""
log_info "Next: run infra/sync-certs.sh after Caddy has obtained TLS certs."
