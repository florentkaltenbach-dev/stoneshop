# StoneShop Known Issues

## CRITICAL — Must fix before migration

### 1. Six plugins not managed by Composer

**Status:** In progress (agent working on old server)

These plugins are active but not in composer.json. They live only in the Docker named volume and would be lost on a fresh build:

- WP-Piwik (Matomo) 1.1.1
- Google Listings & Ads 3.5.3
- Pinterest for WooCommerce 1.4.25
- TikTok for Business 1.3.8
- WooCommerce PayPal Payments 3.4.1
- WooCommerce Services 3.5.1

**Fix:** Add all six to composer.json. Test that `docker compose build` produces a working image with all plugins present and active.

### 2. CrowdSec enrollment key location unknown

**Status:** Not started

The CrowdSec enrollment key and any bouncer API keys may not be in the current .env file. They might have been set interactively or stored in a CrowdSec config file inside the container.

**Fix:** On old server, run `docker exec stoneshop_crowdsec cscli console status` and check CrowdSec config. Extract the key and add to config.env.

### 3. Backup script must dump both databases

**Status:** Not verified

The current backup.sh may only dump the stoneshop database, not the matomo database.

**Fix:** Verify on old server. Update backup.sh to explicitly dump both `stoneshop` and `matomo` databases with separate tags if needed.

## IMPORTANT — Address during migration

### 4. Matomo needs separate URL update

**Status:** Not started

`wp search-replace` only touches the WordPress database. Matomo stores its own site URL and trusted_hosts in config.ini.php and its database.

**Fix:** import.sh must include a step to:
1. Update `trusted_hosts[]` in Matomo's config.ini.php
2. Run SQL update on Matomo's `matomo_site` table to update the site URL

### 5. Docker daemon.json check

**Status:** Not verified

The old server may have custom Docker daemon configuration (log rotation, storage driver, default address pools) in /etc/docker/daemon.json.

**Fix:** Check on old server. If custom config exists, replicate in setup.sh.

## RESOLVED

(Items move here when fixed, with date and resolution.)
