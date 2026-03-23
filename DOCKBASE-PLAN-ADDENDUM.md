# Dockbase Plan — Revision Addendum

> **This addendum supersedes the corresponding sections in DOCKBASE-PLAN.md wherever they conflict.**
> The coding agent should read DOCKBASE-PLAN.md first, then apply these corrections.
> Each section references the issue it fixes and the original section it replaces.

---

## Issue 1: Single source of truth for domains, mail domains, and mailboxes

**Problem:** The plan says domain handling is config-only, but Phase 5 (setup-mailcow.sh) hardcodes Mailcow hostnames, domains, and mailbox lists. `domains.conf` handles web routing but mail setup is ad-hoc.

**Fix:** Three config files, not one. Each is the single source of truth for its scope:

### config/domains.conf — web routing only

```conf
# Web routing: domain → backend
# Used by: generate-caddyfile.sh
# Add a line, regenerate, reload Caddy.

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

### config/mail-domains.conf — mail domains and mailboxes

```conf
# Mail domains and mailboxes
# Used by: setup-mailcow.sh (reads this to add domains + mailboxes via Mailcow API)
# Used by: dns-records.sh (reads this to output MX/SPF/DKIM/DMARC records)
# Used by: backup.sh (reads this to know which domains exist for DKIM backup)
#
# Format:
#   [domain]
#   mailbox  Display Name
#
# Add a domain section, re-run setup-mailcow.sh (idempotent — skips existing).

[fraefel.de]
info        Fraefel Info
rechnung    Fraefel Rechnung

[natursteindesign.de]
n.payan         N. Payan
nathalie        Nathalie
peter.fraefel   Peter Fraefel

[steinmetz-mindelheim-shop.de]
post        Post
bestellung  Bestellung

# Future:
# [steinmetz-bad-woerishofen.de]
# info      Info
```

### config.env — secrets and server-level config (unchanged role)

Still holds `SERVER_IP`, `MAIL_HOSTNAME`, `DEPLOY_MODE`, database passwords, etc. No domain lists, no mailbox lists.

### How the three files interact

| Question | Answered by |
|----------|-------------|
| Which domains get web routes? | `domains.conf` |
| Which domains get mail? What mailboxes? | `mail-domains.conf` |
| What's the mail server hostname? | `config.env` → `MAIL_HOSTNAME` |
| What DNS records does a domain need? | `dns-records.sh` reads both files + `config.env` |
| Where are the secrets? | `config.env` |

**No domain or mailbox is hardcoded in any script.** `setup-mailcow.sh` reads `mail-domains.conf` and calls the Mailcow API for each entry. `generate-caddyfile.sh` reads `domains.conf`. `dns-records.sh` reads both to determine which records a domain needs (web-only, mail-only, or both).

### Supersedes

- Section 5 (Domain routing): add `mail-domains.conf` alongside `domains.conf`
- Section 9, Phase 5 (setup-mailcow.sh): remove all hardcoded domains/mailboxes, read from `mail-domains.conf`
- Section 11 (New files): add `config/mail-domains.conf`
- Section 12 (File tree): add `config/mail-domains.conf`

---

## Issue 2: Backup tag migration and consistency

**Problem:** Current backup uses tags `db`, `uploads`, `languages`, `matomo`. The new plan uses `stoneshop`, `mailcow`, `website`, `matomo-shop`, `matomo-web`. There's no migration path, and the `--restore` section and backup architecture section describe slightly different models.

### Decision: new tag scheme, migration script, one consistent model

**New tags (final):**

| Tag | Contents | Restore target |
|-----|----------|---------------|
| `shop-db` | SQL dump of `stoneshop` database | MariaDB `stoneshop` database |
| `shop-files` | uploads/, languages/ | Bind mounts in /opt/dockbase/web/app/ |
| `shop-matomo` | matomo_shop volume + `matomo_shop` SQL dump | Matomo shop container + MariaDB |
| `web-matomo` | matomo_web volume + `matomo_web` SQL dump | Matomo web container + MariaDB |
| `web-files` | /opt/website/public/ | Website content directory |
| `mailcow` | mailcow backup dir (vmail, SQL, DKIM, etc.) | /opt/mailcow/ restore |

**Why separate `shop-db` and `shop-files`:** Matches current granularity. You might want to restore the database without overwriting uploads (or vice versa). Lumping them into one `stoneshop` tag loses that flexibility.

### Migration from old tags

The first backup after migration writes new tags. Old snapshots in the Restic repo keep their old tags (`db`, `uploads`, `languages`, `matomo`) and remain restorable.

`import.sh` with `--restore` handles both:

```bash
# If old-format snapshots exist (detected by checking for 'db' tag):
#   Restore using old tags: db, uploads, languages, matomo
#   This is the migration restore path.
#
# If new-format snapshots exist (detected by checking for 'shop-db' tag):
#   Restore using new tags.
#
# The first backup.sh run after migration creates new-format snapshots.
# Old snapshots are retained until Restic forget prunes them.
```

### Backup script flow (single canonical version)

```bash
# backup.sh — runs daily at 04:30
# Mode-aware: reads DEPLOY_MODE from config.env, only backs up active stacks.

# 1. Healthcheck gate — wait for all active containers healthy (5-min timeout)
# 2. Shop backup (if mode is full or shop):
#    a. mysqldump stoneshop → /tmp/backup/shop-db/stoneshop.sql
#    b. restic backup /tmp/backup/shop-db/ --tag shop-db
#    c. restic backup /opt/dockbase/web/app/uploads/ /opt/dockbase/web/app/languages/ --tag shop-files
# 3. Shop Matomo backup (if mode is full or shop):
#    a. mysqldump matomo_shop → /tmp/backup/shop-matomo/matomo_shop.sql
#    b. docker cp matomo-shop volume → /tmp/backup/shop-matomo/data/
#    c. restic backup /tmp/backup/shop-matomo/ --tag shop-matomo
# 4. Mailcow backup (if mode is full or mail):
#    a. Run mailcow's helper-scripts/backup_and_restore.sh backup → /opt/mailcow-backup/
#    b. restic backup /opt/mailcow-backup/ --tag mailcow
# 5. Web Matomo backup (if mode is full or web):
#    a. mysqldump matomo_web → /tmp/backup/web-matomo/matomo_web.sql
#    b. docker cp matomo-web volume → /tmp/backup/web-matomo/data/
#    c. restic backup /tmp/backup/web-matomo/ --tag web-matomo
# 6. Website backup (if mode is full or web):
#    a. restic backup /opt/website/public/ --tag web-files
# 7. Cleanup temp dirs
# 8. restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune
```

### Restore script (single canonical version)

```bash
# restore.sh <tag> [snapshot-id]
# Tags: shop-db, shop-files, shop-matomo, web-matomo, web-files, mailcow
# Also accepts legacy tags: db, uploads, languages, matomo
# If snapshot-id omitted, restores 'latest' for that tag.

# After restore, prints the manual steps needed (import SQL, chown, etc.)
# Same pattern as current restore.sh but with expanded tag list.
```

### import.sh --restore flow (single canonical version)

```bash
# import.sh [--skip-restore]
# Called by deploy.sh when --restore flag is set.
# Mode-aware: only restores tags relevant to DEPLOY_MODE.

# 1. Detect snapshot format (old tags vs new tags)
# 2. Shop restore (if mode is full or shop):
#    a. Stop FrankenPHP + Matomo shop (keep MariaDB + KeyDB running)
#    b. Restore shop-db (or legacy: db) → import SQL into MariaDB
#    c. Restore shop-files (or legacy: uploads + languages) → rsync into bind mounts
#    d. If OLD_DOMAIN set: wp search-replace
#    e. Restore shop-matomo (or legacy: matomo) → import into matomo-shop container + DB
#    f. Update Matomo shop URL and trusted_hosts
#    g. Start FrankenPHP + Matomo shop
# 3. Mailcow restore (if mode is full or mail):
#    a. Restore mailcow tag → run mailcow's restore script
# 4. Website restore (if mode is full or web):
#    a. Restore web-files → rsync into /opt/website/public/
#    b. Restore web-matomo → import into matomo-web container + DB
#    c. Update Matomo web URL and trusted_hosts
# 5. Healthcheck all active services
```

### Supersedes

- Section 14 (Backup architecture): replace entirely with above
- Section 9, Phase 8 (Restore): replace entirely with import.sh flow above
- Section 16, Decision 9: update tag names

---

## Issue 3: Multi-mode resume/state model

**Problem:** The current `.deploy-state` is a flat file with phase names (`harden`, `setup`, `import`). With modes, running `--mode shop` (marking phases done) then later `--mode full` would incorrectly skip those phases — but mail and web haven't been set up.

### Decision: mode-prefixed state entries

State file format changes from:

```
harden
setup
import
```

To:

```
full:harden
full:setup-shared
full:setup-caddy
full:setup-shop
full:setup-mailcow
full:setup-website
full:backup-cron
full:verify
```

### Rules

1. **Shared phases are mode-prefixed too.** `full:harden` and `shop:harden` are different entries. This means switching from `--mode shop` to `--mode full` re-runs harden (which is idempotent — it just adds mail ports to UFW).

2. **`--reset` clears all entries** (same as today).

3. **`--reset-mode <mode>` clears entries for that mode only** (new). Useful for: "I ran full but mail failed, let me just redo the mail parts" → `--reset-mode mail` then `--mode mail`.

4. **Phase check function:**

```bash
phase_done() {
    grep -qx "${DEPLOY_MODE}:$1" "$STATE_FILE" 2>/dev/null
}

mark_done() {
    echo "${DEPLOY_MODE}:$1" >> "$STATE_FILE"
}
```

5. **Cross-mode awareness for shared infra:** If you've already done `shop:harden` and now run `--mode full`, the full deploy needs harden to include mail ports. Since `full:harden` isn't in the state file, it re-runs. Harden is idempotent, so this is safe. Same for Docker install, Caddy, etc.

### Supersedes

- Section 6, "How modes work internally": add state model detail
- Section 9, Phase 0: update state tracking description

---

## Issue 4: CrowdSec, logging, and real client IP after Caddy extraction

**Problem:** Currently, FrankenPHP's embedded Caddy writes access logs to `/opt/stoneshop/logs/`, CrowdSec reads them, and Caddy sees real client IPs directly. Moving TLS termination to a shared Caddy proxy breaks this chain:

- The shared Caddy's access logs are the ones with real client IPs — not FrankenPHP's.
- FrankenPHP sees the Docker network IP of the shared Caddy, not the real client.
- CrowdSec needs to read the shared Caddy's logs, not FrankenPHP's.
- WordPress/WooCommerce needs real client IPs for fraud detection, geolocation, and rate limiting.

### Decision: three-part fix

#### 4a. Shared Caddy writes access logs

The shared Caddy container bind-mounts a logs directory:

```yaml
# In shared Caddy's compose
volumes:
  - /opt/dockbase/logs/caddy:/var/log/caddy
```

Every site block in the generated Caddyfile includes:

```caddyfile
log {
    output file /var/log/caddy/access.log
    format json
}
```

This is the single access log for all web traffic. It contains real client IPs.

#### 4b. CrowdSec reads shared Caddy logs

CrowdSec moves from the StoneShop compose to the shared infrastructure. It reads the shared Caddy's log directory:

```yaml
# CrowdSec in shared compose (not StoneShop compose)
crowdsec:
  image: crowdsecurity/crowdsec:latest
  volumes:
    - /opt/dockbase/logs/caddy:/var/log/caddy:ro
    - crowdsec_data:/var/lib/crowdsec/data
  environment:
    COLLECTIONS: "crowdsecurity/caddy crowdsecurity/http-cve crowdsecurity/wordpress"
```

CrowdSec collections remain the same — it's still parsing Caddy JSON logs.

#### 4c. FrankenPHP gets real client IPs via headers

The shared Caddy automatically sets `X-Forwarded-For`, `X-Forwarded-Proto`, and `X-Real-IP` headers when proxying. FrankenPHP's internal Caddy must trust these headers.

FrankenPHP's Caddyfile (the internal one, embedded in the container) changes:

```caddyfile
{
    # No longer handles TLS — shared Caddy does that
    # No longer binds 80/443 — listens on :8080 only
    frankenphp
    order php_server before file_server
    servers {
        trusted_proxies static private_ranges
    }
}

:8080 {
    root * /app/web
    # ... same PHP handling, security headers, etc.
    # No TLS block, no email for ACME
    # Access log still written for FrankenPHP-level debugging:
    log {
        output file /var/log/caddy/frankenphp.log
        format json
    }
}
```

The `trusted_proxies static private_ranges` directive (already in the current Caddyfile) tells Caddy to trust `X-Forwarded-For` from Docker network IPs. This means `{http.request.header.X-Forwarded-For}` in logs and `$_SERVER['REMOTE_ADDR']` in PHP will contain the real client IP.

**WordPress/WooCommerce** reads `REMOTE_ADDR` by default. With `trusted_proxies` configured, Caddy sets this correctly. No WordPress config change needed.

#### 4d. What about Mailcow's logs?

Mailcow has its own fail2ban integration and its own log parsing. Don't route Mailcow logs through CrowdSec — let Mailcow handle its own security. The fail2ban jails added in harden.sh (postfix-sasl, dovecot, sogo-auth) read Mailcow's Docker log output, which is separate from the web access log.

### Supersedes

- Section 4 (Architecture): add logging/CrowdSec detail
- Section 9, Phase 4: remove CrowdSec from StoneShop setup, it's now shared infra
- Section 10 (Reuse audit): CrowdSec moves from docker-compose.yml to shared compose
- Section 15 (RAM budget): CrowdSec moves from "shop" to "shared" column

---

## Issue 5: Domain inventory contradictions

**Problem:** `natursteindesign.de` appears as "mail only (no web)" in the domain table at the bottom of the plan, but as a website alias in `domains.conf`. The DNS section lists it under "mail only — no A record needed" but also under "Web-only alias domains." These contradict.

### Decision: natursteindesign.de is both web AND mail

The user explicitly said: "natursteindesign.de, fraefel.de, steinmetz-bad-woerishofen.de, goldmarmor.de will all route to the website fraefel.de." So it's a website alias. It also has mailboxes (n.payan@, nathalie@, peter.fraefel@). So it's both.

### Corrected domain inventory (single canonical version)

| Domain | Web routing | Mail? | Mailboxes | DNS needed |
|--------|------------|-------|-----------|------------|
| stoneshop.de | → shop | no | — | A, CNAME(www) |
| fraefel.de | → website | yes | info@, rechnung@ | A, CNAME(www, mail), MX, SPF, DKIM, DMARC, autoconfig, autodiscover |
| natursteindesign.de | → website | yes | n.payan@, nathalie@, peter.fraefel@ | A, MX, SPF, DKIM, DMARC, autoconfig, autodiscover |
| steinmetz-mindelheim-shop.de | none | yes | post@, bestellung@ | MX, SPF, DKIM, DMARC, autoconfig, autodiscover |
| steinmetz-bad-woerishofen.de | → website | planned | TBD | A (now), mail records later |
| goldmarmor.de | → website | no | — | A |
| mail.fraefel.de | → mailweb | — | — | A |
| matomo.stoneshop.de | → matomo-shop | — | — | A |
| matomo.fraefel.de | → matomo-web | — | — | A |

**Key distinction:** `steinmetz-mindelheim-shop.de` is the only mail-only domain (no web routing, no A record pointing to this server). All other domains with mail also have web routing.

### DNS records for natursteindesign.de (corrected — web + mail)

| Name | Type | Value |
|------|------|-------|
| `@` | A | `<SERVER_IP>` |
| `@` | MX | `10 mail.fraefel.de` |
| `@` | TXT | `v=spf1 mx a:mail.fraefel.de ip4:<SERVER_IP> -all` |
| `dkim._domainkey` | TXT | (generated by Mailcow) |
| `_dmarc` | TXT | `v=DMARC1; p=quarantine; rua=mailto:postmaster@fraefel.de` |
| `autoconfig` | CNAME | `mail.fraefel.de` |
| `autodiscover` | CNAME | `mail.fraefel.de` |

### Supersedes

- Section 13 (DNS records): remove contradiction, use corrected table above
- "Concrete domain assignments" table at bottom of plan: replace entirely
- Section 5, domains.conf example: already correct (natursteindesign.de → website)

---

## Issue 6: Mailcow automation vs manual setup — decision

**Problem:** The plan says "API-based setup from config if mailbox details are in a config file, or skip and let the user set up manually" but doesn't decide which. This blocks implementation.

### Decision: automated by default, manual as fallback

`setup-mailcow.sh` reads `config/mail-domains.conf` and:

1. **Adds each domain** via Mailcow API (`POST /api/v1/add/domain`). Idempotent — if domain exists, skip.
2. **Creates each mailbox** via Mailcow API (`POST /api/v1/add/mailbox`). Idempotent — if mailbox exists, skip.
3. **Generates DKIM** for each domain via Mailcow API (`POST /api/v1/add/dkim`). Idempotent.
4. **Outputs DNS records** needed for each domain (calls `dns-records.sh` per domain).

**Mailbox passwords:** Generated automatically (same `openssl rand` pattern as DB passwords). Written to a one-time output file: `/opt/mailcow/initial-passwords.txt` (chmod 0600, owned by deploy). The deploy summary prints: "Initial mailbox passwords saved to /opt/mailcow/initial-passwords.txt — change them on first login."

**Fallback:** If `mail-domains.conf` is empty or missing, `setup-mailcow.sh` skips domain/mailbox creation and prints: "No mail domains configured. Add domains via Mailcow UI at https://mail.fraefel.de or populate config/mail-domains.conf and re-run."

**Mailcow API key:** Mailcow generates an API key on first boot. `setup-mailcow.sh` retrieves it from the Mailcow database after startup:

```bash
# Get API key from Mailcow's MySQL
MAILCOW_API_KEY=$(docker exec $(docker ps -qf name=mysql-mailcow) \
    mysql -u mailcow -p${MAILCOW_DBPASS} mailcow \
    -se "SELECT api_key FROM api WHERE allow_from = '' LIMIT 1" 2>/dev/null)
```

If no API key exists, the script creates one via the Mailcow database. This is stored in `config.env` as `MAILCOW_API_KEY` for subsequent idempotent runs.

### Supersedes

- Section 9, Phase 5 (setup-mailcow.sh): replace steps 5-7 with automated flow above
- Section 16, Decision 6: mark as decided

---

## Issue 7: RAM budget is a hypothesis, not a settled figure

**Problem:** The 8 GB RAM budget is presented as settled fact, but the estimates are rough. ClamAV alone can vary from 400MB to 1.5GB. Mailcow's actual RAM depends on mail volume, SOGo usage, etc.

### Decision: label it as estimate, add validation step, define the escape hatch

#### Corrected RAM budget table

| Service | Stack | Estimate | Confidence | Notes |
|---------|-------|----------|------------|-------|
| FrankenPHP + WordPress | shop | ~400 MB | high | Known from current server |
| MariaDB (3 DBs) | shop | ~600 MB | high | Known from current server + small overhead for 2 extra DBs |
| KeyDB (512MB hard limit) | shop | ~512 MB | exact | Configured maxmemory |
| Matomo shop | shop | ~250 MB | medium | Depends on traffic volume |
| **Shop subtotal** | | **~1.8 GB** | | |
| CrowdSec | shared | ~150 MB | medium | Can spike during hub pulls |
| Shared Caddy | shared | ~30 MB | high | Static binary, minimal state |
| **Shared subtotal** | | **~0.2 GB** | | |
| Postfix + Dovecot + SOGo | mail | ~500 MB | low | SOGo varies wildly by active sessions |
| Rspamd + ClamAV | mail | ~800 MB | **low** | **ClamAV loads full virus DB into RAM. 400MB baseline, spikes to 1-1.5GB during freshclam updates. This is the single biggest risk.** |
| Mailcow MariaDB + Redis + nginx | mail | ~500 MB | medium | Light mail volume = lower |
| **Mail subtotal** | | **~1.8 GB** | | **Could be 2.5 GB during ClamAV updates** |
| Matomo web | web | ~250 MB | medium | Depends on website traffic |
| OS + sshd + fail2ban + cron | os | ~500 MB | high | |
| **Total estimate** | | **~4.6 GB** | | |
| **Total worst case** | | **~5.8 GB** | | ClamAV spike + high SOGo usage |
| **Available** | | **8.0 GB** | | |
| **Headroom (typical)** | | **~3.4 GB** | | |
| **Headroom (worst case)** | | **~2.2 GB** | | Still safe with 2GB swap |

#### Validation step in deploy

After all services are up, Phase 9 (Verify) should include:

```bash
echo "=== Memory usage ==="
free -h
docker stats --no-stream --format "table {{.Name}}\t{{.MemUsage}}" | sort -k2 -h
```

This gets logged and printed in the deploy summary. If total usage exceeds 6GB on idle, warn.

#### Escape hatch

If RAM is tight in practice:

1. **Disable ClamAV** in Mailcow (`SKIP_CLAMD=y` in mailcow.conf). Saves ~800MB-1.5GB. Rspamd still does spam filtering without virus scanning.
2. **Reduce KeyDB maxmemory** from 512MB to 256MB. Saves ~256MB. More cache eviction but WooCommerce still works.
3. **Move to 16GB VPS.** Hetzner CX32 is ~€3/month more.

These are documented escalation steps, not things to decide now. The 8GB plan is the starting point; the agent should implement it and we validate with real numbers.

### Supersedes

- Section 15 (RAM budget): replace entirely with corrected table above

---

## Summary of all file changes from this addendum

### New files (additional to DOCKBASE-PLAN.md section 11)

| File | Purpose |
|------|---------|
| `config/mail-domains.conf` | Mail domain + mailbox source of truth |

### Modified specs (changes to what DOCKBASE-PLAN.md describes)

| What | Change |
|------|--------|
| CrowdSec | Moves from StoneShop's docker-compose.yml to shared infrastructure compose. Reads shared Caddy logs, not FrankenPHP logs. |
| FrankenPHP Caddyfile | No longer handles TLS. Listens on :8080. Trusts `X-Forwarded-For` from private ranges. |
| `.deploy-state` format | Entries become `mode:phase` instead of just `phase`. |
| Backup tags | `shop-db`, `shop-files`, `shop-matomo`, `web-matomo`, `web-files`, `mailcow` (not the lumped names from the original plan). Legacy tag support in import.sh for migration. |
| setup-mailcow.sh | Reads `mail-domains.conf`, fully automated domain/mailbox creation via API. Generates initial passwords file. |
| Domain inventory | natursteindesign.de is web + mail (not mail-only). steinmetz-mindelheim-shop.de is the only mail-only domain. |
| RAM budget | Labeled as estimate with confidence levels. Includes worst-case column and documented escape hatches. Validation step added to Phase 9. |

---

*End of revision addendum. The coding agent should apply these corrections when implementing DOCKBASE-PLAN.md.*
