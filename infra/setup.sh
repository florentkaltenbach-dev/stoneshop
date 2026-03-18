#!/bin/bash
# StoneShop Setup — Phase 2
# Installs Docker, clones the repo, and boots the stack.
# Run as root after harden.sh.
# Usage: sudo bash setup.sh

set -Eeuo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Must run as root" >&2
    exit 1
fi

REPO_URL="https://github.com/florentkaltenbach-dev/stoneshop.git"
INSTALL_DIR="/opt/stoneshop"

echo "=== StoneShop Setup ==="

# ── Docker CE ─────────────────────────────────────────────
echo "Installing Docker CE..."
if ! command -v docker &>/dev/null; then
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
        gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        > /etc/apt/sources.list.d/docker.list

    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin

    usermod -aG docker deploy
    systemctl enable docker
    echo "Docker installed."
else
    echo "Docker already installed, skipping."
fi

# ── Additional Tools ──────────────────────────────────────
echo "Installing restic, git, gh, rsync..."
apt-get install -y -qq restic git rsync

# GitHub CLI
if ! command -v gh &>/dev/null; then
    (type -p wget >/dev/null || apt-get install -y -qq wget) \
        && mkdir -p -m 755 /etc/apt/keyrings \
        && wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg \
            | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
        && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
        && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
            | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
        && apt-get update -qq \
        && apt-get install -y -qq gh
fi

# ── Clone Repository ─────────────────────────────────────
echo "Cloning repository to ${INSTALL_DIR}..."
if [ -d "$INSTALL_DIR/.git" ]; then
    echo "Repository already exists at ${INSTALL_DIR}, pulling latest..."
    sudo -u deploy git -C "$INSTALL_DIR" pull
elif [ -d "$INSTALL_DIR" ]; then
    echo "Directory exists but is not a git repo — removing stale directory..."
    rm -rf "$INSTALL_DIR"
    sudo -u deploy git clone "$REPO_URL" "$INSTALL_DIR"
else
    mkdir -p "$(dirname "$INSTALL_DIR")"
    sudo -u deploy git clone "$REPO_URL" "$INSTALL_DIR"
fi
chown deploy:project "$INSTALL_DIR"

# ── Move staged config files from /tmp ───────────────────
if [ -f /tmp/stoneshop-config.env ]; then
    mv /tmp/stoneshop-config.env "$INSTALL_DIR/config.env"
    echo "Moved config.env into place."
fi
if [ -f /tmp/stoneshop-backup_key ]; then
    mkdir -p "$INSTALL_DIR/config/backup"
    mv /tmp/stoneshop-backup_key "$INSTALL_DIR/config/backup/backup_key"
    echo "Moved backup_key into place."
fi

# ── Ownership & Permissions ──────────────────────────────
echo "Setting ownership and permissions..."
chown -R deploy:project "$INSTALL_DIR"
find "$INSTALL_DIR" -type d -exec chmod g+s {} +

mkdir -p "$INSTALL_DIR/logs"
chown deploy:stoneshop "$INSTALL_DIR/logs"
chmod 2775 "$INSTALL_DIR/logs"

mkdir -p "$INSTALL_DIR/backups/db" "$INSTALL_DIR/backups/uploads"
chown -R deploy:project "$INSTALL_DIR/backups"

mkdir -p "$INSTALL_DIR/web/app/uploads" "$INSTALL_DIR/web/app/languages"
chown -R 33:1100 "$INSTALL_DIR/web/app/uploads" "$INSTALL_DIR/web/app/languages"
chmod 2775 "$INSTALL_DIR/web/app/uploads" "$INSTALL_DIR/web/app/languages"

# ── config.env ────────────────────────────────────────────
CONFIG_ENV="$INSTALL_DIR/config.env"
if [ ! -f "$CONFIG_ENV" ]; then
    echo ""
    echo "No config.env found — launching interactive configuration wizard..."
    echo ""
    bash "$INSTALL_DIR/infra/configure.sh" "$INSTALL_DIR"

    if [ ! -f "$CONFIG_ENV" ]; then
        echo "ERROR: ${CONFIG_ENV} still not found after configure." >&2
        exit 1
    fi
else
    echo "Existing config.env found, using it."
fi

chmod 0600 "$CONFIG_ENV"
chown deploy:deploy "$CONFIG_ENV"

# Create .env symlink for Docker Compose
ln -sf config.env "$INSTALL_DIR/.env"

# ── Inject Matomo DB password into init.sql ──────────────
MATOMO_DB_PASS=$(grep -m1 '^MATOMO_DATABASE_PASSWORD=' "$CONFIG_ENV" | cut -d= -f2-)
if [ -n "$MATOMO_DB_PASS" ]; then
    sed -i "s|__MATOMO_DB_PASSWORD__|${MATOMO_DB_PASS}|g" "$INSTALL_DIR/config/mariadb/init.sql"
    echo "Injected Matomo DB password into init.sql."
else
    echo "WARNING: MATOMO_DATABASE_PASSWORD not found in config.env. init.sql NOT updated." >&2
fi

# ── SSH config for StorageBox ─────────────────────────────
echo "Setting up StorageBox SSH access..."
BACKUP_KEY="$INSTALL_DIR/config/backup/backup_key"

if [ ! -f "$BACKUP_KEY" ]; then
    echo ""
    echo "Backup SSH key not found at ${BACKUP_KEY}."
    echo "Please place the StorageBox SSH private key there."
    read -r -p "Press Enter after you've placed the key, or Ctrl-C to abort..."
fi

if [ -f "$BACKUP_KEY" ]; then
    chmod 0600 "$BACKUP_KEY"
    chown deploy:deploy "$BACKUP_KEY"

    # SSH config for deploy user
    DEPLOY_SSH_DIR="/home/deploy/.ssh"
    mkdir -p "$DEPLOY_SSH_DIR"

    # Add StorageBox SSH config if not present
    if ! grep -q "Host storagebox" "$DEPLOY_SSH_DIR/config" 2>/dev/null; then
        cat >> "$DEPLOY_SSH_DIR/config" <<SSHCFG

Host storagebox
    HostName u432319.your-storagebox.de
    User u432319
    Port 23
    IdentityFile ${BACKUP_KEY}
    StrictHostKeyChecking accept-new
SSHCFG
        chmod 0600 "$DEPLOY_SSH_DIR/config"
    fi

    chown -R deploy:deploy "$DEPLOY_SSH_DIR"

    # Add StorageBox to known_hosts
    sudo -u deploy ssh-keyscan -p 23 u432319.your-storagebox.de >> "$DEPLOY_SSH_DIR/known_hosts" 2>/dev/null || true
    echo "StorageBox SSH configured."
else
    echo "WARNING: No backup key found. Restic backups will not work until configured." >&2
fi

# ── Restic Repository Init ───────────────────────────────
echo "Checking Restic repository..."
if sudo -u deploy bash -c "source ${CONFIG_ENV} && export RESTIC_REPOSITORY RESTIC_PASSWORD && restic snapshots" &>/dev/null; then
    echo "Restic repository already initialized."
else
    echo "Initializing Restic repository..."
    sudo -u deploy bash -c "source ${CONFIG_ENV} && export RESTIC_REPOSITORY RESTIC_PASSWORD && restic init" || \
        echo "WARNING: Could not init Restic repo. Check backup_key and config.env." >&2
fi

# ── Build & Start Stack ──────────────────────────────────
echo "Building and starting Docker stack..."
cd "$INSTALL_DIR"
sudo -u deploy docker compose build
sudo -u deploy docker compose up -d

echo "Waiting for containers to become healthy..."
TIMEOUT=300
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
    UNHEALTHY=$(docker compose ps --format json 2>/dev/null | \
        jq -r 'select(.Health != "healthy" and .Health != "" and .Health != null) | .Name' 2>/dev/null | wc -l || echo "0")
    if [ "$UNHEALTHY" -eq 0 ]; then
        break
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
done

if [ $ELAPSED -ge $TIMEOUT ]; then
    echo "WARNING: Some containers did not become healthy within ${TIMEOUT}s"
    docker compose ps
else
    echo "All containers healthy."
fi

# ── Cron Jobs ─────────────────────────────────────────────
echo "Setting up cron jobs for deploy user..."

# Remove existing stoneshop cron entries and add fresh ones
CRON_TMP=$(mktemp)
chmod 644 "$CRON_TMP"
sudo -u deploy crontab -l 2>/dev/null | grep -v '/opt/stoneshop/' > "$CRON_TMP" || true
cat >> "$CRON_TMP" <<'CRONEOF'
# StoneShop: WordPress auto-update (04:00 daily)
0 4 * * * /opt/stoneshop/scripts/wp-update.sh >> /opt/stoneshop/logs/wp-updates.log 2>&1
# StoneShop: Backup (04:30 daily)
30 4 * * * /opt/stoneshop/config/backup/scripts/backup.sh
CRONEOF

sudo -u deploy crontab "$CRON_TMP"
rm -f "$CRON_TMP"
echo "Cron jobs installed."

# ── CrowdSec Enrollment ──────────────────────────────────
CROWDSEC_KEY=$(grep -m1 '^CROWDSEC_ENROLL_KEY=' "$CONFIG_ENV" | cut -d= -f2- || true)
if [ -n "$CROWDSEC_KEY" ]; then
    echo "Enrolling CrowdSec..."
    docker exec stoneshop_crowdsec cscli console enroll "$CROWDSEC_KEY" || \
        echo "WARNING: CrowdSec enrollment failed. Enroll manually later." >&2
else
    echo "No CROWDSEC_ENROLL_KEY in config.env. Skipping enrollment."
    echo "To enroll later: docker exec stoneshop_crowdsec cscli console enroll <key>"
fi

echo ""
echo "=== Setup complete ==="
echo ""
echo "Stack status:"
docker compose ps
echo ""
echo "Next steps:"
echo "  1. Run infra/import.sh to restore data from backup"
echo "  2. Verify: curl -I https://\$(grep SITE_DOMAIN ${CONFIG_ENV} | cut -d= -f2)"
echo "  3. Add CrowdSec bouncer for active blocking (optional)"
