# StoneShop Migration Plan

## Pre-migration (on old server)

- [ ] Add 6 unmanaged plugins to composer.json
- [ ] Test that `docker compose build` produces working image with all plugins
- [ ] Verify backup.sh dumps both stoneshop AND matomo databases
- [ ] Extract CrowdSec enrollment key, add to secrets inventory
- [ ] Run a fresh backup to StorageBox with all 4 tags (db, uploads, languages, matomo)
- [ ] Verify Restic snapshot on StorageBox: `restic snapshots --tag db --tag uploads --tag languages --tag matomo`

## Repo preparation (local machine)

- [ ] Clone old repo to local machine
- [ ] Apply all code changes (templating, config.env, infra scripts)
- [ ] Template Caddyfile: hardcoded domains → {$SITE_DOMAIN}, {$TLS_EMAIL}
- [ ] Template docker-compose.yml: env_file, ${SITE_DOMAIN}, 0.0.0.0:443:443
- [ ] Create config.env.example
- [ ] Create .gitignore (config.env, .env, logs/, backups/)
- [ ] Update .dockerignore (infra/, config.env, .env)
- [ ] Create infra/harden.sh
- [ ] Create infra/setup.sh
- [ ] Create infra/import.sh
- [ ] Update config/backup/scripts/backup.sh
- [ ] Update config/backup/scripts/restore.sh
- [ ] Remove .restic-sync.env if tracked
- [ ] Syntax check: `bash -n infra/*.sh`
- [ ] Create new public GitHub repo
- [ ] Push all changes

## Phase 1: Server hardening (new server, as root)

- [ ] curl and run infra/harden.sh
- [ ] Verify: hostname set
- [ ] Verify: deploy user created with correct groups
- [ ] Verify: SSH pubkey only, no root login
- [ ] Verify: SSH from external machine on port 22
- [ ] Verify: UFW active with correct rules (22/tcp, 80/tcp, 443/tcp, 443/udp)
- [ ] Verify: fail2ban active with sshd jail
- [ ] Verify: swap present (2GB)
- [ ] Verify: unattended-upgrades configured, reboot window at 03:00

## Phase 2: Application setup (new server, as root)

- [ ] curl and run infra/setup.sh
- [ ] Verify: Docker CE + Compose + Buildx installed
- [ ] Verify: repo cloned to /opt/stoneshop/
- [ ] Place config.env with real values
- [ ] Verify: .env symlink → config.env
- [ ] Place backup_key (chmod 0600)
- [ ] Verify: StorageBox SSH config for deploy and root
- [ ] Verify: StorageBox in known_hosts
- [ ] Verify: `docker compose build` succeeds
- [ ] Verify: `docker compose up -d` starts all 5 services
- [ ] Verify: all containers healthy via `docker compose ps`
- [ ] Verify: cron jobs installed (04:00 wp-update, 04:30 backup)

## Phase 2b: Data import (new server)

- [ ] Run infra/import.sh
- [ ] Verify: MariaDB + KeyDB start first, databases imported before app containers
- [ ] Verify: uploads restored (~6.6GB)
- [ ] Verify: languages restored (~50MB)
- [ ] Verify: matomo_data volume restored
- [ ] Verify: wp search-replace ran (if OLD_DOMAIN ≠ SITE_DOMAIN)
- [ ] Verify: Matomo trusted_hosts and site URL updated
- [ ] Verify: all containers healthy after full startup

## DNS cutover

- [ ] Lower TTL on DNS records to 300s (do this 24-48 hours before cutover)
- [ ] Update $SITE_DOMAIN A record to new server IP
- [ ] Update matomo.$SITE_DOMAIN A record to new server IP
- [ ] Wait for propagation

## Post-migration verification

- [ ] curl -I https://$SITE_DOMAIN → 200 + HSTS header
- [ ] curl -I https://matomo.$SITE_DOMAIN → Matomo responds
- [ ] WP admin login works (through WPS Hide Login URL)
- [ ] WooCommerce products display with images
- [ ] Redis connected: `docker exec stoneshop_frankenphp wp redis status --path=/app/web/wp`
- [ ] CrowdSec parsing logs: `docker exec stoneshop_crowdsec cscli metrics`
- [ ] CrowdSec sees real client IPs (not 127.0.0.1)
- [ ] Run backup.sh manually, verify Restic snapshot with all 4 tags
- [ ] PayPal/payment gateway test order
- [ ] Check Caddy access logs for real client IPs

## Rollback

If anything is broken after DNS cutover:
1. Point DNS A records back to old server IP
2. Old server is untouched and still running
3. TTL was lowered, so propagation is fast
