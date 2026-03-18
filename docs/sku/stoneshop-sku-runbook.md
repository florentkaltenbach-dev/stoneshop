# StoneShop SKU Runbook

This file is the source of truth for SKU generation and SKU counter handling.

## Scope

- Applies to WooCommerce products (`post_type=product`)
- SKU format: `{PREFIX}{NUMBER}` (example: `NP108`, `NP109`)
- Prefix comes from selected product category
- Number comes from a per-prefix counter
- Counter baseline is `100` for new prefixes (first generated SKU is `PREFIX101`)

## Implementation Files

- Canonical docs in repo:
  - `docs/sku/stoneshop-sku-runbook.md`
  - `docs/sku/category-scheme.md`
- Runtime MU plugins (server):
  - `/opt/stoneshop/web/app/mu-plugins/stoneshop-sku.php`
  - `/opt/stoneshop/web/app/mu-plugins/stoneshop-admin.php`
- Docs on server:
  - `/opt/stoneshop/instructions/stoneshop-sku-runbook.md`

## Data Model

- Category prefix (term meta on `product_cat`)
  - Key: `_sku_prefix`
  - Value: 1-4 uppercase letters (`NP`, `LL`, `MR`, ...)
- Product SKU (post meta)
  - Key: `_sku`
  - Value: generated SKU (`NP109`)
- Counter (option)
  - Key: `_sku_counter_{PREFIX}` (`_sku_counter_NP`)
  - Value: last used integer for that prefix
  - Default for a new prefix: `100`

## Current Product Editor Flow

1. Select one category in the `Produktkategorie` dropdown.
2. Click `Veröffentlichen` or `Aktualisieren`.
3. SKU is generated or preserved automatically.

## Generation Rules

1. Read selected product category.
2. Read `_sku_prefix` of that category.
3. If no prefix exists, skip generation.
4. Prefix resolution is deterministic:
   - Prefer `stoneshop_product_cat` posted from the product editor dropdown.
   - Otherwise use assigned category prefixes; if multiple exist, prefer current SKU prefix when still assigned.
   - If still ambiguous, use stable fallback ordering.
5. If SKU exists and prefix still matches, keep existing SKU.
6. SKU uniqueness checks ignore products in `trash`, `auto-draft`, and `inherit`.
7. Otherwise ensure `_sku_counter_{PREFIX}` exists (default `100`), increment, and set `_sku = PREFIX + counter`.
8. Before assigning, the generator checks if candidate SKU already exists on another active product and skips forward until unique.
9. Generation retries are bounded (`STONESHOP_SKU_MAX_ATTEMPTS`) to avoid infinite loops.
10. Allocation uses a per-prefix DB lock (`GET_LOCK`) so concurrent saves do not allocate the same number.
11. SKU generation is skipped for `trash`, `auto-draft`, and `inherit` statuses.

## Add New Category to SKU System

1. Add category in WooCommerce.
2. Set `_sku_prefix` for that category.
3. Optionally set initial counter manually (`100` means first SKU will be `101`).
4. Save a product in this category once to generate first SKU.

## WP-CLI Commands

- List categories:
  - `docker exec stoneshop_frankenphp wp term list product_cat --fields=term_id,name,slug --format=table --path=/app/web/wp`
- Get prefix:
  - `docker exec stoneshop_frankenphp wp term meta get <TERM_ID> _sku_prefix --path=/app/web/wp`
- Set prefix:
  - `docker exec stoneshop_frankenphp wp term meta update <TERM_ID> _sku_prefix NP --path=/app/web/wp`
- Get counter:
  - `docker exec stoneshop_frankenphp wp option get _sku_counter_NP --path=/app/web/wp`
- Set counter:
  - `docker exec stoneshop_frankenphp wp option update _sku_counter_NP 109 --path=/app/web/wp`
- Show all counters:
  - `docker exec stoneshop_frankenphp wp option list --search='_sku_counter_%' --fields=option_name,option_value --format=table --path=/app/web/wp`

## `sku-init` Backfill Command

- Command: `wp stoneshop sku-init`
- Discovers prefixes dynamically from category term meta (`_sku_prefix`)
- Scans existing product `_sku` values first, then title patterns like `NP108` as fallback
- Initializes counters from max found values per prefix

Important:
- Ensure each category has a valid `_sku_prefix` before running `sku-init`.
- No static mapping maintenance is required for new categories.

## Harmonization Session Checklist

1. Backup DB first.
2. Export products with ID, title, `_sku`, categories.
3. Normalize category assignment (exactly one SKU category where required).
4. Normalize `_sku` to match category prefix and number rules.
5. Normalize title format (for example `Name + SKU`).
6. Re-check counters so next SKU continues correctly.
7. Create one test product and verify generated SKU.

## AI Agent Startup Checklist

1. Read this file.
2. Read `docs/sku/category-scheme.md`.
3. Read runtime MU plugins on server:
   - `/opt/stoneshop/web/app/mu-plugins/stoneshop-sku.php`
   - `/opt/stoneshop/web/app/mu-plugins/stoneshop-admin.php`
4. Verify current counters and sample SKUs before changing anything.
