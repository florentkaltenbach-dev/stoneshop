# Dockbase Final Implementation Plan

> Canonical handoff for the coding agent.
> This file supersedes `DOCKBASE-PLAN.md` and `DOCKBASE-PLAN-ADDENDUM.md` for implementation.
> If this file conflicts with older planning documents, this file wins.

## 1. Goal

Turn the current single-stack `stoneshop` repo into `dockbase`: a modular deployment toolkit for multiple Docker-based services on one Ubuntu 24.04 server.

Initial target stacks:

- Shop: WooCommerce on FrankenPHP, MariaDB, KeyDB, Matomo
- Mail: Mailcow
- Website: static site served by shared Caddy, plus separate Matomo

Hard constraints:

- 8 GB VPS is the chosen target for now
- Idempotent scripts
- Resume-safe deploys
- No hardcoded domains or mailbox lists in scripts
- All WordPress plugins remain Composer-managed
- Mailcow is kept as its own opinionated stack

## 2. Current Repo Reality

The current repo is still a single-stack StoneShop deployment:

- One `docker-compose.yml` for FrankenPHP, MariaDB, KeyDB, Matomo, CrowdSec
- `infra/deploy.sh` supports resumable laptop-driven deploys with `.deploy-state`
- `infra/setup.sh` installs Docker, clones repo, configures backup access, and boots the current stack
- `infra/import.sh` restores legacy Restic tags: `db`, `uploads`, `languages`, `matomo`

The coding agent must refactor from this current shape, not assume Dockbase already exists.

## 3. Target Architecture

### Shared edge

- A standalone shared Caddy instance owns host ports `80`, `443/tcp`, and `443/udp`
- Shared Caddy routes by `Host` header
- Shared Caddy is responsible for public TLS
- Shared Caddy writes the authoritative web access logs
- CrowdSec moves to shared infrastructure and reads shared Caddy logs
- Shared Caddy, the shop-facing services, and website Matomo join a shared external Docker network such as `dockbase-proxy`

### Shop stack

- FrankenPHP no longer binds host `80/443`
- FrankenPHP listens internally on `:8080`
- Shop services stay in the repo-managed compose
- Shop-facing services that need shared edge access join the external `dockbase-proxy` network
- Shop uses one MariaDB instance with:
  - `stoneshop`
  - `matomo_shop`
  - `matomo_web`

### Website stack

- Website content lives in `/opt/dockbase/website/public/`
- Shared Caddy serves static files directly from that path
- Website analytics run in a separate `matomo-web` container and database

### Mail stack

- Mailcow is installed in `/opt/mailcow/`
- Mailcow keeps its own nginx, MariaDB, Redis, and internal compose
- Do not join Mailcow to the shared external Docker network
- Mailcow web ports bind only to localhost on the host:
  - `127.0.0.1:8880`
  - `127.0.0.1:8443`
- Mail-specific ports bypass the shared proxy and go directly to Mailcow:
  - `25`
  - `465`
  - `587`
  - `993`
  - `4190`
- Mailcow web endpoints are reverse proxied by shared Caddy through `host.docker.internal`

## 4. Domain And Mail Source Of Truth

Use three config files with strict scope separation.

### `config/domains.conf`

Purpose: web routing only.

Backends:

- `shop`
- `website`
- `mailweb`
- `matomo-shop`
- `matomo-web`

Canonical initial entries:

```conf
stoneshop.de                         shop
www.stoneshop.de                     shop

fraefel.de                           website
www.fraefel.de                       website
natursteindesign.de                  website
steinmetz-bad-woerishofen.de         website
www.steinmetz-bad-woerishofen.de     website
goldmarmor.de                        website

mail.fraefel.de                      mailweb

matomo.stoneshop.de                  matomo-shop
matomo.fraefel.de                    matomo-web
```

### `config/mail-domains.conf`

Purpose: mail domains and mailbox declarations only.

Canonical initial entries:

```conf
[fraefel.de]
info        Fraefel Info
rechnung    Fraefel Rechnung

[natursteindesign.de]
n.payan         N. Payan
nathalie        Nathalie
peter.fraefel   Peter Fraefel
```

Notes:

- Do not include `steinmetz-mindelheim-shop.de`
- `steinmetz-bad-woerishofen.de` is website-only for now
- `goldmarmor.de` is website-only for now

### `config.env`

Purpose: secrets and server-level config.

Must contain:

- `SERVER_IP`
- `DEPLOY_MODE`
- `TLS_EMAIL`
- `MAIL_HOSTNAME`
- `MAILCOW_API_KEY` optional
- database passwords
- WordPress salts
- Restic config
- StorageBox config

Rules:

- No domain lists here
- No mailbox lists here
- The wizard may generate and populate this file

## 5. Deploy Modes

`infra/deploy.sh` must support:

- `--mode full`
- `--mode shop`
- `--mode mail`
- `--mode web`
- `--restore`
- `--fresh`
- `--reset`
- `--reset-mode <mode>`
- `--configure`
- `--verbose`

Mode behavior:

- `full`: shared infra + shop + mail + website
- `shop`: shared infra + shop only
- `mail`: shared infra + mail only
- `web`: shared infra + website only

Shared phases always run within the active mode, but state tracking remains mode-prefixed.

## 6. State Tracking

State entries must be `mode:phase`, not plain phase names.

Example:

```text
full:harden
full:setup-shared
full:setup-caddy
full:setup-shop
full:setup-mailcow
full:setup-website
full:backup-cron
full:restore
full:verify
```

Rules:

- `phase_done()` checks `${DEPLOY_MODE}:$PHASE`
- `mark_done()` writes `${DEPLOY_MODE}:$PHASE`
- `--reset` clears the full state file
- `--reset-mode <mode>` removes only entries for that mode
- Re-running shared phases across modes is expected and safe because scripts must be idempotent

## 7. Shared Caddy, Logging, And Real Client IP

### Shared Caddy

- Shared Caddy gets a generated `config/caddy/Caddyfile`
- It bind-mounts `/opt/dockbase/logs/caddy:/var/log/caddy`
- Every generated site block writes JSON logs to `/var/log/caddy/access.log`
- Shared Caddy joins the external `dockbase-proxy` network
- Shared Caddy must include `extra_hosts: ["host.docker.internal:host-gateway"]`
- Shared Caddy reverse proxies Mailcow web traffic to `host.docker.internal` on `127.0.0.1`-bound Mailcow ports, not to Mailcow Docker networks

### CrowdSec

- CrowdSec moves out of the shop stack
- CrowdSec becomes part of shared infrastructure
- CrowdSec reads `/opt/dockbase/logs/caddy`
- CrowdSec continues using the Caddy and WordPress-related collections
- CrowdSec joins shared infrastructure only; it is not part of the shop compose

### FrankenPHP internal Caddy

- FrankenPHP keeps a separate internal app config at `config/caddy/frankenphp.Caddyfile`
- This internal config listens on `:8080`
- It does not manage TLS
- It trusts proxy headers from private Docker ranges
- Keep security headers and PHP handling there
- Keep an internal debug log separate from the shared edge access log
- The generated edge Caddyfile remains at `config/caddy/Caddyfile`
- Matomo reverse proxy blocks belong in the generated edge Caddyfile, not in `frankenphp.Caddyfile`

Result:

- Shared Caddy sees real client IPs
- CrowdSec parses the right logs
- WordPress receives correct client IP information through trusted proxy handling

## 8. Mailcow Integration Policy

Mailcow integration must follow a fixed fallback order. The coding agent may try the next option only if the previous one fails or is unsupported.

### Preferred order

1. Deploy Mailcow using documented reverse-proxy settings.
2. Put shared Caddy in front of Mailcow web endpoints.
3. Let shared Caddy manage public TLS.
4. Sync proxy-managed certs back into Mailcow for SMTP/IMAP/webmail certificate use.
5. If `MAILCOW_API_KEY` is present, automate domain, DKIM, and mailbox setup via Mailcow API.
6. If `MAILCOW_API_KEY` is missing, check for a documented and supported non-interactive bootstrap path in Mailcow docs or repo scripts.
7. If no supported bootstrap path exists, deploy Mailcow infrastructure fully, skip mailbox/domain automation, and print exact manual next steps.

### Hard rules

- Do not make direct Mailcow DB reads or writes the default bootstrap path for API access
- Prefer official Mailcow-documented flows first
- If falling back, stop short of undocumented schema hacks unless the coding agent verifies they are already part of Mailcow’s own supported workflow
- The implementation must remain idempotent whichever path is selected

### Mailcow config targets

`setup-mailcow.sh` should generate `mailcow.conf` with at least:

- `MAILCOW_HOSTNAME=mail.fraefel.de`
- `HTTP_BIND=127.0.0.1`
- `HTTP_PORT=8880`
- `HTTPS_BIND=127.0.0.1`
- `HTTPS_PORT=8443`
- `SKIP_LETS_ENCRYPT=y`

### Certificate handling

- Shared Caddy owns certificate issuance
- A post-renew or sync script copies certs into Mailcow’s `data/assets/ssl/`
- The script restarts the relevant Mailcow containers after cert updates

### Mail autoconfig scope

Initial v1 scope:

- `mail.fraefel.de` is required
- `autoconfig` and `autodiscover` support is optional and may be implemented only if the coding agent can do so cleanly within Mailcow’s documented reverse-proxy model
- If not implemented, the deployment output must state that mail clients require manual configuration
- Host fail2ban remains `sshd`-only; do not add host-level jails for Postfix, Dovecot, or SOGo because Mailcow already ships its own `mailcow-fail2ban` handling for mail services

## 9. Deployment Phases

### Phase 1: Harden

- Harden Ubuntu host
- Create deploy user
- SSH key-only auth, no root login
- UFW rules are mode-aware
- Mail ports open only in `full` and `mail`
- Unattended upgrades with reboot window at `03:00`
- Host fail2ban remains `sshd`-only

### Phase 2: Shared setup

- Install Docker CE, Compose, Buildx, restic, git, rsync
- Clone repo to `/opt/dockbase/`
- Place `config.env`
- Create `.env` symlink
- Configure StorageBox access

### Phase 3: Shared Caddy

- Generate `config/caddy/Caddyfile` from `config/domains.conf`
- Start shared Caddy
- Start shared CrowdSec
- Ensure the shared external Docker network exists
- Verify ports `80/443` respond

### Phase 4: Shop

- Refactor repo-managed compose so FrankenPHP is internal-only on `:8080`
- Add separate `matomo-shop` and `matomo-web` services
- Ensure MariaDB init creates `matomo_shop` and `matomo_web`
- Add `config/caddy/frankenphp.Caddyfile` and mount it into the FrankenPHP container
- Join shop-facing services to the external `dockbase-proxy` network where needed
- Build shop image
- Start shop services for active modes
- CrowdSec is no longer part of the shop compose

### Phase 5: Mailcow

- Clone `mailcow-dockerized` to `/opt/mailcow`
- Generate `mailcow.conf`
- Start Mailcow
- Bind Mailcow web ports to localhost only and reverse proxy them from shared Caddy via `host.docker.internal`
- If API automation is available, apply `config/mail-domains.conf`
- If API automation is not available, stop cleanly with exact next steps

### Phase 6: Website

- Create `/opt/dockbase/website/public/`
- Place placeholder or pulled website content
- Start `matomo-web` when mode includes website
- Verify website routes through shared Caddy

### Phase 7: Backup and cron

- Install cron jobs
- `04:00` WP update only in shop-containing modes
- `04:30` Restic backup for active stacks

### Phase 8: Restore

- Runs only with `--restore`
- Mode-aware
- Prefer new backup tags when available
- Fall back to legacy tags only for migration restores

### Phase 9: Verify

- Check active containers
- Check HTTPS for active domains
- Print summary
- Print memory usage for visibility only

## 10. Backup And Restore Model

Final canonical tags:

- `shop-db`
- `shop-files`
- `shop-matomo`
- `web-files`
- `web-matomo`
- `mailcow`

Legacy tags still supported for migration:

- `db`
- `uploads`
- `languages`
- `matomo`

### Restore precedence

- If new-format tags exist for a stack, use them
- Use legacy tags only when new-format tags do not yet exist

### Backup flow

Shop:

- dump `stoneshop` to `shop-db`
- back up uploads and languages to `shop-files`
- dump and copy shop Matomo data to `shop-matomo`

Website:

- back up `/opt/dockbase/website/public/` to `web-files`
- dump and copy web Matomo data to `web-matomo`

Mailcow:

- use Mailcow’s own backup tooling
- then snapshot the backup output to Restic as `mailcow`

### Import flow

Shop:

- keep MariaDB and KeyDB up
- stop app-facing shop containers as needed
- restore DB
- restore files
- run `wp search-replace` when `OLD_DOMAIN` is set
- restore shop Matomo

Website:

- restore site files
- restore web Matomo

Mailcow:

- restore Mailcow using Mailcow’s own restore tooling

## 11. Files To Create Or Change

### New files

- `DOCKBASE-PLAN-FINAL.md`
- `config/domains.conf`
- `config/mail-domains.conf`
- `config/caddy/frankenphp.Caddyfile`
- `infra/setup-shop.sh`
- `infra/setup-mailcow.sh`
- `infra/setup-website.sh`
- `infra/setup-caddy.sh`
- `infra/generate-caddyfile.sh`
- `infra/dns-records.sh`
- `infra/add-domain.sh`
- `infra/lib/common.sh`
- `infra/lib/progress.sh`

### Existing files to refactor

- `infra/deploy.sh`
- `infra/harden.sh`
- `infra/setup.sh`
- `infra/import.sh`
- `infra/configure.sh`
- `docker-compose.yml`
- `config/mariadb/init.sql`
- `config/backup/scripts/backup.sh`
- `config/backup/scripts/restore.sh`
- `README.md`
- `DECISIONS.md`
- `MIGRATION-PLAN.md`
- `KNOWN-ISSUES.md`
- `SECRETS-INVENTORY.md`

## 12. Acceptance Criteria

The implementation is complete when all of the following are true:

- `shop` mode deploys shared infra plus shop only
- `mail` mode deploys shared infra plus Mailcow only
- `web` mode deploys shared infra plus website only
- `full` mode deploys all three stacks
- Shop works behind shared Caddy on internal `:8080`
- CrowdSec reads shared Caddy logs
- New and legacy backup tags both restore correctly during migration
- State tracking works safely across repeated runs and across mode switches
- `natursteindesign.de` is both website and mail
- `steinmetz-bad-woerishofen.de` and `www.steinmetz-bad-woerishofen.de` are website-only
- No `steinmetz-mindelheim-shop.de` appears anywhere in the implementation
- Mailcow deploys behind shared Caddy
- Mailcow certificate sync from shared Caddy is implemented
- Mail automation either completes through a supported path or exits with clean manual instructions
- Host fail2ban remains `sshd`-only
- Mailcow is not joined to the shared Docker proxy network

## 13. Defaults And Assumptions

- 8 GB VPS is accepted for initial implementation
- If Mailcow API bootstrap cannot be done through a supported path, the deploy remains one-click for infrastructure but not for mailbox/domain provisioning
- The wizard may gather missing human inputs, generate secrets, and write `config.env`
- The coding agent should prefer official documentation and stable integration paths over clever hacks
