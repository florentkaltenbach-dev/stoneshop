# StoneShop — Project Memory

## What is this?

A WooCommerce shop running on Docker (FrankenPHP + MariaDB + Redis + Matomo + CrowdSec), designed for one-click deployment to a fresh Ubuntu 24.04 server.

## Current phase: Migration to new server

See `docs/migration/` for full details:

- `ARCHITECTURE.md` — infrastructure diagram in prose, source of truth
- `DECISIONS.md` — every decision with reasoning and date
- `MIGRATION-PLAN.md` — phased checklist with status tracking
- `KNOWN-ISSUES.md` — blockers and fixes
- `SECRETS-INVENTORY.md` — every secret, where it lives, transfer status

## Hard rules

- **Clean fixes only.** No volume hacks, no manual plugin installs, no workarounds.
- **All plugins via Composer.** Nothing lives only in a Docker volume.
- **One config file.** All secrets and site-specific config in `config.env`. The `.env` symlink exists only for Docker Compose parse-time interpolation.
- **Idempotent scripts.** Every script in `infra/` must be safely re-runnable.
- **No hardcoded domains.** Everything uses `$SITE_DOMAIN` from config.env.

## Repo structure

```
stoneshop/
├── CLAUDE.md                  ← you are here
├── config.env.example         ← template for secrets + site config
├── docker-compose.yml
├── Dockerfile
├── config/
│   ├── caddy/Caddyfile
│   └── backup/
│       ├── backup_key         ← git-ignored, SSH key for StorageBox
│       └── scripts/
│           ├── backup.sh
│           └── restore.sh
├── infra/
│   ├── harden.sh              ← phase 1: generic Ubuntu hardening
│   ├── setup.sh               ← phase 2: Docker + app setup
│   └── import.sh              ← phase 2b: data restore from Restic
├── scripts/
│   └── wp-update.sh
├── web/
│   └── app/
│       ├── themes/            ← bind-mounted
│       ├── mu-plugins/        ← bind-mounted
│       └── .well-known/       ← bind-mounted
└── docs/
    └── migration/
```

## Key technical details

- WordPress URLs in database require `wp search-replace` on domain change
- Matomo needs separate URL/trusted_hosts update on domain change
- Backup runs daily at 04:30, after WP auto-update at 04:00, after reboot window at 03:00
