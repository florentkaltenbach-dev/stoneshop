# Dockbase — Project Expansion Plan

> **Handoff document for the coding agent.**
> This captures every decision, architecture detail, and implementation spec from the planning session.
> The agent should treat this as the source of truth for building the expanded project.

## Table of contents

1. [What is dockbase?](#1-what-is-dockbase)
2. [Current state (stoneshop)](#2-current-state-stoneshop)
3. [Target state (dockbase)](#3-target-state-dockbase)
4. [Architecture](#4-architecture)
5. [Domain routing](#5-domain-routing)
6. [Install modes](#6-install-modes)
7. [CLI UX — progress bar and logging](#7-cli-ux--progress-bar-and-logging)
8. [Smart configuration wizard](#8-smart-configuration-wizard)
9. [Deployment phases (detailed)](#9-deployment-phases-detailed)
10. [Reuse audit — every existing file](#10-reuse-audit--every-existing-file)
11. [New files to create](#11-new-files-to-create)
12. [Target file tree](#12-target-file-tree)
13. [DNS records](#13-dns-records)
14. [Backup architecture](#14-backup-architecture)
15. [RAM budget](#15-ram-budget)
16. [Decisions log](#16-decisions-log)
17. [Hard rules](#17-hard-rules)
18. [Implementation order](#18-implementation-order)

---

## 1. What is dockbase?

Dockbase is a modular, one-click deployment toolkit for running multiple Docker-based services on a single Ubuntu 24.04 server. It deploys a WooCommerce shop, a Mailcow mail server, and a static website — each independently installable and restorable.

**Repo name:** `dockbase`
**Tagline:** Your base for all Docker services.
**License:** Open source (to be decided, likely MIT).

The project evolves from `stoneshop`, which was a single-service WooCommerce deployment tool. Dockbase generalizes it into a multi-stack platform.

---

## 2. Current state (stoneshop)

The existing `stoneshop` repo deploys a single WooCommerce stack:

- **5 Docker services:** FrankenPHP (Caddy + PHP + WordPress), MariaDB, KeyDB, Matomo, CrowdSec
- **3 infra scripts:** `harden.sh` (server hardening), `setup.sh` (Docker + app), `import.sh` (Restic data restore)
- **1 orchestrator:** `deploy.sh` — runs from laptop, SSH into server, phased execution with state tracking
- **1 config file:** `config.env` (all secrets, git-ignored, `.env` symlink for Docker Compose)
- **Backup:** Daily Restic to Hetzner StorageBox
- **Repo:** Public GitHub, bootstrap scripts curl-able from raw.githubusercontent.com

Key properties of the current system that must be preserved:
- Idempotent scripts (safe to re-run)
- State tracking via `.deploy-state` (resume after failure)
- No hardcoded domains (everything via `$SITE_DOMAIN` from config.env)
- All plugins via Composer (nothing lives only in a volume)

---

## 3. Target state (dockbase)

### Three independent stacks on one 8GB Hetzner VPS

| Stack | Services | Domain(s) |
|-------|----------|-----------|
| **StoneShop** | FrankenPHP, MariaDB, KeyDB, CrowdSec, Matomo (shop) | stoneshop.de |
| **Mailcow** | Postfix, Dovecot, SOGo, Rspamd, ClamAV, own MariaDB, own Redis, own nginx | mail.fraefel.de (webmail + SMTP host) |
| **Website** | Static files served by shared Caddy | fraefel.de, natursteindesign.de, steinmetz-bad-woerishofen.de, goldmarmor.de |

### Shared infrastructure

- **Shared Caddy reverse proxy** — owns ports 80/443, routes by Host header
- **Restic backup** — tagged per stack, independently restorable
- **UFW + fail2ban** — mode-aware firewall rules
- **Unattended upgrades** — auto-reboot at 03:00
- **Logrotate + cron** — maintenance scheduling

### Key properties

- Each stack is independently deployable (`--mode shop|mail|web|full`)
- Each stack is independently restorable from backup
- Adding a domain is config-only, not code (edit `domains.conf`, regenerate Caddyfile)
- Analytics are split: two Matomo instances (shop + web), separate databases, separate containers
- Restore is opt-in (`--restore` flag) for fast iteration during testing
- CLI shows progress bar, not wall of text; logs go to file

---

## 4. Architecture

### Network flow

```
Internet → :22          → sshd (pubkey only, no root login)
Internet → :25/465/587  → Mailcow (Postfix — direct, no proxy)
Internet → :993         → Mailcow (Dovecot IMAPS — direct, no proxy)
Internet → :80/443      → Shared Caddy reverse proxy
                            ├── stoneshop.de         → FrankenPHP :8080
                            ├── fraefel.de + aliases  → file_server /opt/website/public
                            ├── mail.fraefel.de      → Mailcow nginx :8443
                            ├── matomo.stoneshop.de   → matomo-shop :80
                            └── matomo.fraefel.de     → matomo-web :80
```

### Port map

| Port | Protocol | Listener | Purpose |
|------|----------|----------|---------|
| 22/tcp | SSH | sshd | Remote access, pubkey auth only |
| 25/tcp | SMTP | Mailcow (Postfix) | Incoming mail |
| 80/tcp | HTTP | Shared Caddy | HTTPS redirect + ACME HTTP-01 |
| 443/tcp | HTTPS | Shared Caddy | TLS termination, host-based routing |
| 443/udp | QUIC | Shared Caddy | HTTP/3 |
| 465/tcp | SMTPS | Mailcow (Postfix) | Secure SMTP submission |
| 587/tcp | Submission | Mailcow (Postfix) | SMTP submission (STARTTLS) |
| 993/tcp | IMAPS | Mailcow (Dovecot) | Secure IMAP |
| 4190/tcp | ManageSieve | Mailcow (Dovecot) | Sieve filter management |

### Port conflict resolution

The central architectural challenge: Mailcow ships its own nginx on 80/443, and StoneShop's FrankenPHP also wants 80/443.

**Solution:** A standalone shared Caddy container owns ports 80/443 and routes by `Host` header. StoneShop's FrankenPHP moves to an internal port (8080). Mailcow's HTTP is proxied on `mail.fraefel.de`. Mail-specific ports (25, 465, 587, 993, 4190) bypass the proxy entirely and go direct to Mailcow containers.

Mailcow's built-in nginx ACME is disabled — set `HTTP_BIND` and `HTTPS_BIND` to internal ports in `mailcow.conf`. The shared Caddy handles all TLS termination.

### Docker network topology

- **frontend** network: Shared Caddy, Matomo containers
- **backend** network: StoneShop services (FrankenPHP, MariaDB, KeyDB, CrowdSec)
- **Mailcow** uses its own Docker Compose with its own networks (don't fight it)
- Shared Caddy connects to both frontend and the Mailcow network to proxy webmail

### Database layout

All in the StoneShop MariaDB instance (Mailcow runs its own):

| Database | Owner | Purpose |
|----------|-------|---------|
| `stoneshop` | StoneShop | WordPress/WooCommerce |
| `matomo_shop` | Matomo shop | Analytics for stoneshop.de |
| `matomo_web` | Matomo web | Analytics for fraefel.de |

Mailcow runs its own MariaDB container with its own databases (mailcow, SOGo). Do not share databases with Mailcow.

---

## 5. Domain routing

### domains.conf — single source of truth

No domains are hardcoded in any script. All domain-to-backend mapping lives in `config/domains.conf`:

```conf
# config/domains.conf
# Format: domain  backend
# Backends: shop, website, mailweb, matomo-shop, matomo-web
#
# Add a line, run generate-caddyfile.sh, reload Caddy. Done.

stoneshop.de                    shop
www.stoneshop.de                shop

fraefel.de                      website
www.fraefel.de                  website
natursteindesign.de             website
steinmetz-bad-woerishofen.de    website
goldmarmor.de                   website

mail.fraefel.de                 mailweb

matomo.stoneshop.de             matomo-shop
matomo.fraefel.de               matomo-web
```

### How domain routing works

1. `generate-caddyfile.sh` reads `domains.conf` + `config.env` (for backend ports/paths)
2. Groups domains by backend
3. Outputs a Caddyfile with one block per backend group
4. Caddy reload picks up changes

### Adding a new domain

**New web domain (e.g., goldmarmor.de → website):**
1. Add line to `domains.conf`: `goldmarmor.de  website`
2. Run `./infra/generate-caddyfile.sh`
3. Reload Caddy: `docker exec caddy caddy reload --config /etc/caddy/Caddyfile`
4. Run `./infra/dns-records.sh goldmarmor.de web` → outputs A record to paste into registrar
5. Set DNS at registrar

**New mail domain (e.g., goldmarmor.de for email):**
1. Add domain in Mailcow UI (generates DKIM keys)
2. Create mailboxes in Mailcow UI
3. Run `./infra/dns-records.sh goldmarmor.de mail` → outputs MX, SPF, DKIM, DMARC records
4. Set DNS records at registrar

**No script changes required for either operation.**

### Generated Caddyfile structure

```caddyfile
# Auto-generated by generate-caddyfile.sh — do not edit manually
# Source: config/domains.conf

stoneshop.de, www.stoneshop.de {
    reverse_proxy frankenphp:8080
}

fraefel.de, www.fraefel.de,
natursteindesign.de,
steinmetz-bad-woerishofen.de,
goldmarmor.de {
    root * /srv/website/public
    file_server
}

mail.fraefel.de {
    reverse_proxy mailcow-nginx:8443 {
        transport http {
            tls_insecure_skip_verify
        }
    }
}

matomo.stoneshop.de {
    reverse_proxy matomo-shop:80
}

matomo.fraefel.de {
    reverse_proxy matomo-web:80
}
```

---

## 6. Install modes

Single `deploy.sh` with a `--mode` flag. Each mode runs only the phases it needs.

### Mode: full (default)

```bash
./deploy.sh 203.0.113.1
./deploy.sh 203.0.113.1 --restore
```

Phases: Harden → Docker + tools → Shared Caddy → StoneShop → Mailcow → Website → Backup + cron → Verify

### Mode: shop

```bash
./deploy.sh 203.0.113.1 --mode shop
```

Phases: Harden → Docker + tools → Shared Caddy → StoneShop → Matomo shop → Backup + cron → Verify

Portable: move the shop to its own server with its own analytics. No mail, no website. UFW only opens 22, 80, 443.

### Mode: mail

```bash
./deploy.sh 203.0.113.1 --mode mail
```

Phases: Harden → Docker + tools → Shared Caddy → Mailcow → Backup + cron → Verify

Standalone mail server. Caddy only serves mail.fraefel.de webmail. UFW opens mail ports.

### Mode: web

```bash
./deploy.sh 203.0.113.1 --mode web
```

Phases: Harden → Docker + tools → Shared Caddy → Website → Matomo web → Backup + cron → Verify

Lightweight static site server with its own analytics. UFW only opens 22, 80, 443.

### The --restore flag

- **Without `--restore` (default):** Sets up all services with empty databases. WordPress runs its installer, Mailcow starts fresh, website serves placeholder. Full deploy takes ~5 minutes. This is the fast iteration path.
- **With `--restore`:** After services are up, triggers Restic restore per stack. Only restores what's in the active mode — `--mode shop --restore` only restores shop data, not mailcow volumes. Each restore is tagged: `--tag stoneshop`, `--tag mailcow`, `--tag website`.

### How modes work internally

`deploy.sh` sets a `DEPLOY_MODE` variable (full/shop/mail/web). Each phase script checks it before running:

```bash
# In setup-mailcow.sh
source /opt/dockbase/infra/lib/common.sh
require_mode "full" "mail"   # Only runs in full or mail mode
```

The shared phases (harden, docker, caddy proxy, backup) always run. The `domains.conf` is filtered by mode — shop-only generates a Caddyfile with only shop routes. Harden adjusts UFW: mail ports only open in `full` and `mail` modes.

### Other flags

| Flag | Purpose |
|------|---------|
| `--fresh` | Clear known_hosts for this IP (use after server rebuild) |
| `--reset` | Clear deploy state and start all phases from scratch |
| `--restore` | Trigger Restic data import after setup |
| `--configure` | Force re-run of configuration wizard even if config.env exists |
| `--verbose` | Stream all script output to terminal (old behavior) |
| `--mode <mode>` | full (default), shop, mail, web |

---

## 7. CLI UX — progress bar and logging

### Current problem

The current `deploy.sh` dumps hundreds of lines of apt-get, Docker build, and git output to the terminal. Failures are buried in noise. There's no indication of progress.

### New design

**What the user sees:**

```
 Dockbase Deploy — full mode
 ─────────────────────────────────

 ✓ Harden server          00:42
 ✓ Install Docker          01:15
 ✓ Shared Caddy proxy      00:08
 ◼ StoneShop stack    ━━━━━━━━░░ 80%
   Building FrankenPHP image...
 ○ Mailcow
 ○ Website
 ○ Backup & cron
 ○ Verify

 Log: /tmp/deploy-20260323-1422.log
```

**On failure:**

```
 ✗ StoneShop stack         FAILED

 Last 10 lines from log:
 > docker compose build --progress=plain
 > ERROR: failed to solve: process "/bin/sh -c composer install"
 > did not complete successfully: exit code: 1

 Full log: /tmp/deploy-20260323-1422.log
```

### Implementation

- All stdout/stderr from remote scripts → log file. The deploy.sh wrapper captures all output.
- **Local log:** `/tmp/deploy-{date}-{time}.log` (the full SSH session, on your laptop)
- **Server log:** `/opt/deploy.log` (raw script output per phase)
- Progress updates via structured marker lines: `#PROGRESS:phase_name:percentage:message`. The local deploy.sh parses these over SSH and updates the progress bar.
- `--verbose` flag restores old behavior — all output streams to terminal.

### Progress bar library

Create `infra/lib/progress.sh` — sourced by all phase scripts:

```bash
# Usage in phase scripts:
source /opt/dockbase/infra/lib/progress.sh

progress 10 "Installing Docker CE..."
apt-get install -y docker-ce ...
progress 40 "Cloning repository..."
git clone ...
progress 80 "Building images..."
docker compose build ...
progress 100 "Done"
```

The `progress` function writes `#PROGRESS:$PHASE:$PCT:$MSG` to a sideband fd that deploy.sh reads.

---

## 8. Smart configuration wizard

### Two paths to a config.env

1. **Pre-filled file (fast iteration):** Place a `config.env` next to `deploy.sh`. It's used as-is, wizard is skipped.
2. **Wizard (from scratch / new user):** If no `config.env` exists, the wizard launches automatically. Can also be forced with `--configure`.

### What the wizard asks (5-8 questions)

| Variable | Source | Logic |
|----------|--------|-------|
| `DEPLOY_MODE` | **ask** | Which services? [full / shop / mail / web] |
| `SERVER_IP` | **derive** | Already passed as CLI argument |
| `SITE_DOMAIN` | **ask** | Only in full/shop mode. Shop domain. |
| `WEBSITE_DOMAIN` | **ask** | Only in full/web mode. Website domain. |
| `MAIL_HOSTNAME` | **derive** | `mail.${WEBSITE_DOMAIN}` — ask only if different |
| `TLS_EMAIL` | **derive** | `admin@${WEBSITE_DOMAIN}` — ask only if different |
| `OLD_DOMAIN` | **ask** | Only with `--restore`. Previous domain for wp search-replace. |
| `STORAGEBOX_HOST` | **ask** | Hetzner StorageBox hostname. Skip if no backup_key. |
| `STORAGEBOX_USER` | **ask** | Usually uXXXXXX |

### What the wizard auto-generates

| Variable | Method |
|----------|--------|
| `MYSQL_ROOT_PASSWORD` | `openssl rand`, 32 chars |
| `MYSQL_PASSWORD` | `openssl rand`, 32 chars |
| `MATOMO_DATABASE_PASSWORD` | `openssl rand`, 32 chars |
| `MATOMO_WEB_DB_PASSWORD` | `openssl rand`, 32 chars |
| `RESTIC_PASSWORD` | `openssl rand`, 32 chars |
| `AUTH_KEY` + 7 more WP salts | `openssl rand`, 64 chars each |

### What the wizard sets to defaults

| Variable | Default |
|----------|---------|
| `STORAGEBOX_PORT` | 23 (Hetzner standard) |
| `RESTIC_REPOSITORY` | `sftp:storagebox:/backups/dockbase` |
| `CROWDSEC_ENROLL_KEY` | empty (user adds later) |

### Smart behaviors

- **Mode-aware prompting:** In `--mode shop`, skip website domain, mail hostname, and mail questions entirely.
- **Smart default cascade:** Type `fraefel.de` as website domain → auto-suggests `mail.fraefel.de` for mail and `admin@fraefel.de` for TLS email. Press Enter to accept.
- **Existing config preservation:** Running wizard on existing config.env shows current values in brackets. Enter keeps old value. Secrets show `[keep existing]` and are never regenerated unless explicitly asked.
- **domains.conf auto-populated:** After wizard completes, it generates an initial `domains.conf` from your answers.
- **Validation:** Checks domains look valid (contain a dot, no spaces), StorageBox host resolves, backup_key exists if StorageBox configured. Warnings, not blockers.

### Wizard output

```
 ╔══════════════════════════════════════╗
 ║      Dockbase Configuration Wizard   ║
 ╚══════════════════════════════════════╝

 Deploy mode
   ❯ full   shop   mail   web

 Domains
   Shop domain:     stoneshop.de
   Website domain:  fraefel.de
   Mail hostname:   [mail.fraefel.de] ← Enter to accept

 TLS / Let's Encrypt
   Contact email:   [admin@fraefel.de] ← Enter to accept

 Backup (StorageBox)
   Host:            uXXXXXX.your-storagebox.de
   User:            uXXXXXX
   Port:            [23] ← Enter to accept

 ── Auto-generated secrets ──────────────────
   ✓ 4 database passwords generated
   ✓ 8 WordPress salts generated
   ✓ Restic password generated
 ──────────────────────────────────────────

 Saved: ./config.env
 Also generated: ./config/domains.conf
```

---

## 9. Deployment phases (detailed)

### Phase 0: Pre-deploy (runs on laptop)

1. Parse CLI arguments (`--mode`, `--restore`, `--fresh`, `--reset`, `--verbose`, `--configure`)
2. If no `config.env` → launch wizard (section 8)
3. If `config.env` exists → source it, validate required vars for the active mode
4. Detect SSH key (same logic as current deploy.sh)
5. Probe server: determine if root or deploy user is available

### Phase 1: Harden — `harden.sh`

**Reuse: ~85% from current.** Changes: mode-aware UFW, extra fail2ban jails.

1. Create `deploy` user with sudo, copy root's SSH keys — **reuse**
2. Harden SSH: pubkey only, no root login — **reuse**
3. Configure UFW — **modify:**
   - Always: 22/tcp, 80/tcp, 443/tcp, 443/udp
   - Only in `full` and `mail` modes: 25/tcp, 465/tcp, 587/tcp, 993/tcp, 4190/tcp
   - The mode is passed as an argument: `harden.sh <mode>`
4. Install fail2ban with sshd jail — **reuse**
5. Add fail2ban jails for mail — **new** (only in full/mail mode):
   - `postfix-sasl` jail
   - `dovecot` jail
   - `sogo-auth` jail
6. Sysctl hardening — **reuse**
7. Create 2GB swap — **reuse**
8. Configure unattended-upgrades (auto-reboot 03:00) — **reuse**
9. Logrotate for /opt/dockbase/logs/ — **reuse** (update path from stoneshop)
10. Install essential packages (curl, wget, htop, tmux, jq) — **reuse**

### Phase 2: Setup (shared) — `setup.sh`

**Reuse: ~70%.** Becomes shared-only; stack-specific setup moves to own scripts.

1. Install Docker CE, Compose, Buildx — **reuse**
2. Install restic, git, rsync — **reuse**
3. Clone repo to `/opt/dockbase/` — **modify** (new repo URL)
4. Move config.env + backup_key from /tmp staging — **reuse**
5. Create `.env` symlink → `config.env` — **reuse**
6. StorageBox SSH config + known_hosts — **reuse**
7. Restic repository init — **reuse**

Does NOT start any Docker services. That's handled by stack-specific scripts.

### Phase 3: Shared Caddy — `setup-caddy.sh` — NEW

1. Generate Caddyfile from `domains.conf` (filtered by active mode)
2. Create a minimal Docker Compose for the shared Caddy container
3. Caddy container binds 80/443 on host
4. Start Caddy, verify it responds on 80/443
5. TLS certificates auto-provisioned on first request per domain (ACME HTTP-01)

### Phase 4: StoneShop — `setup-shop.sh` — NEW (extracted from current setup.sh)

Only runs in `full` and `shop` modes.

1. Create databases in MariaDB: `stoneshop`, `matomo_shop`
2. Build FrankenPHP image (`docker compose build`)
3. Start StoneShop services: FrankenPHP (:8080 internal), MariaDB, KeyDB, CrowdSec
4. Start Matomo shop container
5. Wait for all containers healthy
6. CrowdSec enrollment (if key provided)
7. Install cron: WP auto-update at 04:00

FrankenPHP no longer binds ports 80/443 — it listens on :8080 and the shared Caddy proxy forwards to it.

### Phase 5: Mailcow — `setup-mailcow.sh` — NEW

Only runs in `full` and `mail` modes.

1. Clone `mailcow-dockerized` to `/opt/mailcow/`
2. Generate `mailcow.conf` from `config.env` values:
   - `MAILCOW_HOSTNAME=mail.fraefel.de`
   - `HTTP_BIND=127.0.0.1` (internal only — shared Caddy handles HTTPS)
   - `HTTPS_BIND=127.0.0.1`
   - `HTTP_PORT=8880` (internal)
   - `HTTPS_PORT=8443` (internal)
   - Disable ACME in Mailcow (Caddy handles TLS)
   - `SKIP_LETS_ENCRYPT=y`
   - Timezone, DB passwords
3. Start Mailcow stack: `cd /opt/mailcow && docker compose up -d`
4. Wait for Mailcow healthy
5. Add mail domains via Mailcow API: fraefel.de, natursteindesign.de, steinmetz-mindelheim-shop.de
6. Create mailboxes via Mailcow API:
   - fraefel.de: info@, rechnung@
   - natursteindesign.de: n.payan@, nathalie@, peter.fraefel@
   - steinmetz-mindelheim-shop.de: post@, bestellung@
7. Generate DKIM keys for each domain
8. Output DNS records that need to be set (or run dns-records.sh)

**Important:** Mailcow is opinionated — it keeps its own nginx, MariaDB, Redis. Don't fight it. Let it run its own full stack in `/opt/mailcow/`. The only integration point is the shared Caddy proxy for webmail HTTPS and the shared backup system.

The initial mailbox creation could also be done manually through the Mailcow UI after deploy. The script should support both: API-based setup from config if mailbox details are in a config file, or skip and let the user set up manually.

### Phase 6: Website — `setup-website.sh` — NEW

Only runs in `full` and `web` modes.

1. Create website content directory: `/opt/website/public/`
2. Deploy placeholder or actual content (git clone a website repo, or create index.html)
3. Start Matomo web container (separate from Matomo shop)
4. Verify website accessible through shared Caddy

The website is served directly by the shared Caddy via `file_server` — no extra container needed for static content. If the user later wants a CMS, they add a container.

### Phase 7: Backup + cron — part of setup.sh or separate

1. Expand `backup.sh` to snapshot all active stacks with per-stack tags
2. Install cron jobs:
   - 03:00 — unattended-upgrades reboot window (already in harden.sh)
   - 04:00 — WP auto-update (only in shop mode)
   - 04:30 — Restic backup (all active stacks)

### Phase 8: Restore (only with --restore flag)

Only runs if `--restore` was passed.

1. Mode-aware: only restore tags for active stacks
2. StoneShop restore:
   - Stop FrankenPHP + Matomo (keep MariaDB + KeyDB running)
   - Restic restore `--tag stoneshop` (DB, uploads, languages)
   - Restic restore `--tag matomo-shop` (Matomo data)
   - Run `wp search-replace` if `OLD_DOMAIN` is set
   - Update Matomo shop URL and trusted_hosts
   - Restart all services
3. Mailcow restore:
   - Use mailcow's built-in backup restore, or Restic restore `--tag mailcow` (vmail, DB dump)
4. Website restore:
   - Restic restore `--tag website` (content files)
   - Restic restore `--tag matomo-web` (Matomo web data)
5. Healthcheck all services

### Phase 9: Verify

1. `docker compose ps` for all active stacks
2. Check HTTPS for each domain in `domains.conf`
3. Print summary with URLs and status

---

## 10. Reuse audit — every existing file

| Current file | Status | What changes |
|-------------|--------|-------------|
| `infra/deploy.sh` | **modify** | Add `--mode`, `--restore`, `--configure`, `--verbose` flags. Progress bar UI. Mode-aware phase dispatch. Log file redirect. |
| `infra/harden.sh` | **modify** | Mode-aware UFW rules (mail ports only in full/mail). Extra fail2ban jails for postfix/dovecot/sogo. Progress markers. Update paths from stoneshop → dockbase. |
| `infra/setup.sh` | **modify** | Becomes shared-only setup (Docker, tools, repo clone). Stack-specific setup moves to own scripts. Progress markers. Update repo URL and paths. |
| `infra/import.sh` | **modify** | Becomes mode-aware: only restores tags for active stacks. Only runs with `--restore` flag. Add matomo-web restore. Update paths. |
| `infra/configure.sh` | **modify** | Expand wizard with mode selection, website domain, mail hostname sections. Mode-aware prompting. Auto-generate domains.conf. |
| `docker-compose.yml` | **modify** | FrankenPHP loses port 80/443 binds → internal :8080. Add matomo-shop + matomo-web as separate services. Add shared Caddy service (or separate compose file). Add matomo_web database in MariaDB init. |
| `config/caddy/Caddyfile` | **replace** | Replaced by auto-generated Caddyfile from domains.conf. Old file deleted. |
| `config.env.example` | **modify** | Add `SERVER_IP`, `DEPLOY_MODE`, `MAIL_HOSTNAME`, `WEBSITE_DOMAIN`, `MATOMO_WEB_DB_PASSWORD`. Add mailcow section. Add website section. |
| `config/mariadb/init.sql` | **modify** | Add `matomo_web` database and user creation alongside existing `matomo` (now `matomo_shop`). |
| `Dockerfile` | **reuse** | Unchanged — StoneShop's FrankenPHP image. |
| `composer.json` | **reuse** | Unchanged. |
| `.dockerignore` | **reuse** | Unchanged. |
| `scripts/wp-update.sh` | **reuse** | Unchanged. |
| `config/backup/scripts/backup.sh` | **modify** | Add mailcow + website backup with separate `--tag` per stack. Mode-aware (only backup active stacks). Add mailcow backup integration (use mailcow's built-in script or dump separately). |
| `config/backup/scripts/restore.sh` | **modify** | Add mailcow + website restore tags. Mode-aware. |
| `web/app/mu-plugins/*` | **reuse** | Unchanged — SKU system, admin customizations. |
| `web/app/themes/*` | **reuse** | Unchanged. |
| `docs/migration/ARCHITECTURE.md` | **modify** | Rewrite for multi-stack architecture. |
| `docs/migration/DECISIONS.md` | **modify** | Add all new decisions (section 16). |
| `docs/migration/MIGRATION-PLAN.md` | **modify** | Expand for multi-stack. |
| `CLAUDE.md` | **modify** | Update project memory for dockbase. |
| `README.md` | **modify** | Rewrite for dockbase. New usage examples, new architecture diagram. |

---

## 11. New files to create

| File | Purpose |
|------|---------|
| `config/domains.conf` | Domain → backend mapping. Single source of truth for all routing. |
| `infra/setup-shop.sh` | StoneShop-specific setup: build image, create DBs, start containers, CrowdSec enrollment. |
| `infra/setup-mailcow.sh` | Clone mailcow-dockerized, generate mailcow.conf, start stack, add domains/mailboxes via API. |
| `infra/setup-website.sh` | Deploy static site content, start matomo-web container. |
| `infra/setup-caddy.sh` | Generate Caddyfile from domains.conf, create and start shared Caddy container. |
| `infra/generate-caddyfile.sh` | Reads `domains.conf` + `config.env` → writes Caddyfile. Idempotent. Run on domain add/remove. |
| `infra/dns-records.sh` | Reads `config.env` + `domains.conf` → outputs DNS records per domain. Usage: `./dns-records.sh <domain> [web\|mail\|both]` or `./dns-records.sh --all`. |
| `infra/add-domain.sh` | Wrapper: adds line to domains.conf, runs generate-caddyfile.sh, reloads Caddy, runs dns-records.sh. |
| `infra/lib/progress.sh` | Shared progress bar library sourced by all phase scripts. Writes structured `#PROGRESS:` markers. |
| `infra/lib/common.sh` | Shared helpers: env loading, health checks, `require_mode()`, logging setup. |

---

## 12. Target file tree

```
dockbase/
├── CLAUDE.md                              # Project memory (update)
├── README.md                              # Rewrite for dockbase
├── config.env.example                     # Expanded template
├── config/
│   ├── domains.conf                       # NEW — domain routing config
│   ├── caddy/
│   │   └── Caddyfile                      # GENERATED — do not edit manually
│   ├── mariadb/
│   │   ├── custom.cnf                     # Reuse
│   │   └── init.sql                       # Modify — add matomo_web DB
│   └── backup/
│       ├── backup_key                     # Reuse (git-ignored)
│       └── scripts/
│           ├── backup.sh                  # Modify — multi-stack tags
│           └── restore.sh                 # Modify — multi-stack tags
├── docker-compose.yml                     # Modify — internal ports, 2 Matomo services, shared Caddy
├── Dockerfile                             # Reuse
├── composer.json                          # Reuse
├── .dockerignore                          # Reuse
├── infra/
│   ├── deploy.sh                          # Modify — modes, progress, --restore
│   ├── harden.sh                          # Modify — mode-aware UFW
│   ├── setup.sh                           # Modify — shared setup only
│   ├── import.sh                          # Modify — mode-aware restore
│   ├── configure.sh                       # Modify — expanded wizard
│   ├── setup-shop.sh                      # NEW
│   ├── setup-mailcow.sh                   # NEW
│   ├── setup-website.sh                   # NEW
│   ├── setup-caddy.sh                     # NEW
│   ├── generate-caddyfile.sh              # NEW
│   ├── dns-records.sh                     # NEW
│   ├── add-domain.sh                      # NEW
│   └── lib/
│       ├── progress.sh                    # NEW
│       └── common.sh                      # NEW
├── scripts/
│   └── wp-update.sh                       # Reuse
├── web/
│   └── app/
│       ├── themes/                        # Reuse
│       ├── mu-plugins/                    # Reuse
│       └── .well-known/                   # Reuse
└── docs/
    ├── migration/
    │   ├── ARCHITECTURE.md                # Modify
    │   ├── DECISIONS.md                   # Modify
    │   └── MIGRATION-PLAN.md              # Modify
    └── sku/                               # Reuse
        ├── stoneshop-sku-runbook.md
        └── category-scheme.md
```

---

## 13. DNS records

### PTR record (set in Hetzner Cloud console)

```
<SERVER_IP> → mail.fraefel.de
```

This is critical for mail deliverability. One IP = one PTR = the mail hostname wins.

### fraefel.de (website + mail)

| Name | Type | Value |
|------|------|-------|
| `fraefel.de` | A | `<SERVER_IP>` |
| `www` | CNAME | `fraefel.de` |
| `mail` | A | `<SERVER_IP>` |
| `@` | MX | `10 mail.fraefel.de` |
| `@` | TXT | `v=spf1 a mx ip4:<SERVER_IP> -all` |
| `dkim._domainkey` | TXT | (generated by Mailcow) |
| `_dmarc` | TXT | `v=DMARC1; p=quarantine; rua=mailto:postmaster@fraefel.de` |
| `autoconfig` | CNAME | `mail.fraefel.de` |
| `autodiscover` | CNAME | `mail.fraefel.de` |
| `_autodiscover._tcp` | SRV | `0 1 443 mail.fraefel.de` |

### stoneshop.de (web only)

| Name | Type | Value |
|------|------|-------|
| `stoneshop.de` | A | `<SERVER_IP>` |
| `www` | CNAME | `stoneshop.de` |
| `matomo` | A | `<SERVER_IP>` |

### natursteindesign.de (mail only — no A record needed)

| Name | Type | Value |
|------|------|-------|
| `@` | MX | `10 mail.fraefel.de` |
| `@` | TXT | `v=spf1 mx a:mail.fraefel.de ip4:<SERVER_IP> -all` |
| `dkim._domainkey` | TXT | (generated by Mailcow per domain) |
| `_dmarc` | TXT | `v=DMARC1; p=quarantine; rua=mailto:postmaster@fraefel.de` |
| `autoconfig` | CNAME | `mail.fraefel.de` |
| `autodiscover` | CNAME | `mail.fraefel.de` |

### steinmetz-mindelheim-shop.de (mail only — same pattern as above)

Same records as natursteindesign.de.

### Web-only alias domains (natursteindesign.de, steinmetz-bad-woerishofen.de, goldmarmor.de)

If these only point to the website (no mail), they just need:

| Name | Type | Value |
|------|------|-------|
| `@` | A | `<SERVER_IP>` |

### IP change workflow

1. Update `SERVER_IP` in `config.env`
2. Run `./infra/dns-records.sh --all` → outputs every DNS record for every domain with new IP
3. Update PTR in Hetzner Cloud console → `mail.fraefel.de`
4. Update records at each domain registrar (manual, but the script tells you exactly what)

---

## 14. Backup architecture

### Strategy

Single Restic repository on Hetzner StorageBox. Per-stack tags for independent restore.

### Tags

| Tag | What's included |
|-----|----------------|
| `stoneshop` | WordPress DB dump, uploads, languages |
| `matomo-shop` | Matomo shop volume + DB dump |
| `mailcow` | Mailcow backup (vmail, DB, DKIM keys) via mailcow's `helper-scripts/backup_and_restore.sh` |
| `matomo-web` | Matomo web volume + DB dump |
| `website` | Website content (/opt/website/public/) |

### Schedule

| Time | Job |
|------|-----|
| 03:00 | Unattended-upgrades reboot window |
| 04:00 | WP auto-update (shop mode only) |
| 04:30 | Restic backup (all active stacks) |

### Backup script flow

```bash
# backup.sh (expanded)
# 1. Healthcheck gate (5-min timeout)
# 2. Dump databases per stack
# 3. If mailcow active: run mailcow's backup script → output dir
# 4. Restic backup with per-stack tags
# 5. Restic forget (prune old snapshots per retention policy)
```

### Restore workflow

```bash
# Restore just the shop:
./infra/restore.sh stoneshop
./infra/restore.sh matomo-shop

# Restore just mailcow:
./infra/restore.sh mailcow

# Restore just website + its analytics:
./infra/restore.sh website
./infra/restore.sh matomo-web
```

---

## 15. RAM budget

Target: 8 GB VPS.

| Service | Stack | RAM estimate |
|---------|-------|-------------|
| FrankenPHP + WordPress | shop | ~400 MB |
| MariaDB (shop + 2× matomo DBs) | shop | ~600 MB |
| KeyDB (512MB limit) | shop | ~512 MB |
| Matomo shop | shop | ~250 MB |
| CrowdSec | shop | ~150 MB |
| **Shop subtotal** | | **~1.9 GB** |
| Postfix + Dovecot + SOGo | mail | ~500 MB |
| Rspamd + ClamAV | mail | ~800 MB |
| Mailcow MariaDB + Redis + nginx | mail | ~500 MB |
| **Mail subtotal** | | **~1.8 GB** |
| Shared Caddy reverse proxy | shared | ~30 MB |
| Matomo web | web | ~250 MB |
| Static site (file_server) | web | ~0 MB |
| **Web subtotal** | | **~0.3 GB** |
| OS + sshd + fail2ban + cron | os | ~500 MB |
| **Total estimated** | | **~4.5 GB** |
| **Available** | | **8.0 GB** |
| **Headroom** | | **~3.5 GB** |

ClamAV is the wildcard — it loads virus signatures into RAM and can spike to 1GB+ during updates. With 3.5GB headroom this is absorbed easily. The 2GB swap covers edge cases.

---

## 16. Decisions log

These extend the existing `DECISIONS.md`. Each needs the date 2026-03-23.

### Decision 1: Project rename — stoneshop → dockbase

**Decision:** Rename the repo from `stoneshop` to `dockbase`.
**Reasoning:** The project now hosts three services (shop, mail, website), not just a shop. `dockbase` is generic, open-source-friendly, and reflects the Docker-based multi-stack nature.
**Status:** To implement.

### Decision 2: Install modes (full/shop/mail/web)

**Decision:** One `deploy.sh` with `--mode` flag. Shared infra always runs. Stack-specific phases conditional on mode.
**Reasoning:** Enables independent deployment and portability. Each stack can be deployed to its own server. A shop-only deploy doesn't install mailcow or open mail ports.
**Status:** To implement.

### Decision 3: Restore is opt-in (--restore)

**Decision:** Default deploy creates empty services. `--restore` triggers Restic import.
**Reasoning:** Faster iteration during testing — a clean deploy takes ~5min vs ~15min with restore. Lets you set up infrastructure first and import data later.
**Status:** To implement.

### Decision 4: Progress bar UI, logs to file

**Decision:** `deploy.sh` shows minimal progress display. All script output redirected to timestamped log file. `--verbose` flag for old behavior.
**Reasoning:** Wall-of-text output hides failures. Progress bar makes state obvious. Log file preserves everything for debugging.
**Status:** To implement.

### Decision 5: Two Matomo instances

**Decision:** `matomo-shop` (stoneshop.de) and `matomo-web` (fraefel.de) run as separate containers with separate databases.
**Reasoning:** Independent backup/restore. Each stack is fully portable — move the shop to another server and take its analytics with it.
**Status:** To implement.

### Decision 6: Domain routing via domains.conf

**Decision:** No hardcoded domains in any script. Single config file maps domains to backends. Caddyfile is generated from it.
**Reasoning:** Adding a domain = one line + one command + DNS update. No code changes required. Supports open-source use by other people with different domains.
**Status:** To implement.

### Decision 7: Shared Caddy reverse proxy

**Decision:** Standalone Caddy container owns ports 80/443. Routes by Host header. FrankenPHP moves to internal :8080. Mailcow HTTP proxied on mail.fraefel.de. Mail ports (25/465/587/993/4190) go direct to Mailcow.
**Reasoning:** Port conflict resolution. Three services want HTTP(S) — one proxy to rule them all.
**Status:** To implement.

### Decision 8: Mailcow runs its own stack

**Decision:** Don't fight Mailcow's architecture. Let it keep its own nginx, MariaDB, Redis in /opt/mailcow with its own Docker Compose.
**Reasoning:** Mailcow is opinionated. Sharing DBs or Redis creates upgrade pain and breaks mailcow's update scripts.
**Status:** To implement.

### Decision 9: Backup tagged per stack

**Decision:** Restic snapshots use `--tag stoneshop`, `--tag mailcow`, `--tag website`, `--tag matomo-shop`, `--tag matomo-web`. Restore is per-tag.
**Reasoning:** Independent restorability matches the independent deployment model. Move a stack to another server and restore just its backup.
**Status:** To implement.

### Decision 10: PTR record → mail.fraefel.de

**Decision:** Single IP, single PTR, always the mail hostname.
**Reasoning:** Mail deliverability requires matching PTR + HELO. One IP = one PTR = mail wins. Web traffic is unaffected by PTR.
**Status:** To implement.

### Decision 11: Smart configuration wizard

**Decision:** If no config.env exists, an interactive wizard launches. It asks 5-8 human-only questions, derives what it can, generates all secrets. Pre-filled config.env skips the wizard.
**Reasoning:** New open-source users need guided setup. The owner keeps fast iteration with a pre-filled file. Both paths produce the same config.env.
**Status:** To implement.

---

## 17. Hard rules

Carried over from the original project and expanded:

1. **Clean fixes only.** No volume hacks, no manual plugin installs, no workarounds.
2. **All WordPress plugins via Composer.** Nothing lives only in a Docker volume.
3. **One config file.** All secrets and site-specific config in `config.env`. The `.env` symlink exists only for Docker Compose parse-time interpolation.
4. **Idempotent scripts.** Every script in `infra/` must be safely re-runnable.
5. **No hardcoded domains.** Everything uses variables from `config.env` and routes from `domains.conf`.
6. **Each stack is independently portable.** Shop, mail, and website can each be deployed alone on their own server with `--mode`.
7. **Each stack is independently restorable.** Backup tags separate the stacks. Restoring one doesn't require restoring the others.
8. **Progress, not noise.** CLI shows progress bar. Logs go to file. Failures are surfaced clearly.
9. **Config, not code, for domain changes.** Adding a domain never requires editing a script.
10. **Don't fight Mailcow.** It gets its own stack, its own compose, its own databases. Integration is only through the shared Caddy proxy.

---

## 18. Implementation order

Suggested order for the coding agent, based on dependency chain:

### Phase A: Foundation (everything else depends on this)

1. **Rename repo structure** — stoneshop → dockbase paths everywhere
2. **`infra/lib/common.sh`** — shared helpers (env loading, `require_mode()`, health checks)
3. **`infra/lib/progress.sh`** — progress bar library
4. **`config.env.example`** — expanded template with all new variables
5. **`config/domains.conf`** — initial domain routing file
6. **`infra/generate-caddyfile.sh`** — reads domains.conf, outputs Caddyfile

### Phase B: Core orchestration

7. **`infra/deploy.sh`** — rewrite with modes, flags, progress UI, log redirect
8. **`infra/configure.sh`** — expanded wizard with mode-aware prompting
9. **`infra/harden.sh`** — update with mode-aware UFW + mail fail2ban jails

### Phase C: Stack setup scripts

10. **`infra/setup.sh`** — slim down to shared-only (Docker, tools, clone)
11. **`infra/setup-caddy.sh`** — shared Caddy container setup
12. **`infra/setup-shop.sh`** — extracted StoneShop setup
13. **`infra/setup-mailcow.sh`** — Mailcow installation and configuration
14. **`infra/setup-website.sh`** — website deployment

### Phase D: Docker Compose updates

15. **`docker-compose.yml`** — FrankenPHP to :8080, add matomo-shop + matomo-web, shared Caddy
16. **`config/mariadb/init.sql`** — add matomo_web database

### Phase E: Backup and restore

17. **`config/backup/scripts/backup.sh`** — multi-stack with per-stack tags
18. **`config/backup/scripts/restore.sh`** — multi-stack restore
19. **`infra/import.sh`** — mode-aware, --restore flag integration

### Phase F: Domain tools

20. **`infra/dns-records.sh`** — DNS record generator
21. **`infra/add-domain.sh`** — domain addition wrapper

### Phase G: Documentation

22. **`README.md`** — full rewrite for dockbase
23. **`CLAUDE.md`** — update project memory
24. **`docs/migration/ARCHITECTURE.md`** — multi-stack architecture
25. **`docs/migration/DECISIONS.md`** — add all new decisions

---

## Concrete domain assignments (for reference)

| Domain | Service | Mail? | Mailboxes |
|--------|---------|-------|-----------|
| stoneshop.de | WooCommerce shop | no | — |
| fraefel.de | Company website | yes | info@, rechnung@ |
| natursteindesign.de | Website alias + mail | yes | n.payan@, nathalie@, peter.fraefel@ |
| steinmetz-mindelheim-shop.de | Mail only | yes | post@, bestellung@ |
| steinmetz-bad-woerishofen.de | Website alias | planned | TBD |
| goldmarmor.de | Website alias | no | — |
| mail.fraefel.de | Mailcow webmail | — | — |
| matomo.stoneshop.de | Shop analytics | — | — |
| matomo.fraefel.de | Website analytics | — | — |

**Mail-only domains** (natursteindesign.de, steinmetz-mindelheim-shop.de) don't need A records pointing to the server — only MX/SPF/DKIM/DMARC pointing to mail.fraefel.de.

**Website alias domains** (natursteindesign.de, steinmetz-bad-woerishofen.de, goldmarmor.de) all route to the same static website as fraefel.de.

---

*End of handoff document.*
