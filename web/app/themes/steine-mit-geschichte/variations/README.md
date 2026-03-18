# Variation Register

This document tracks variant slots used for layout/design experiments.
Typography and color are baked into the base theme; variants are temporary and must be removed after a winner is chosen.

## Quick Start

```bash
# View variants in browser (admin/dev only)
?variant=v0
?variant=v1
?variant=v2
?variant=v3
?variant=v4
?variant=v5

# Or set default in config (currently v5)
define('SMG_VARIATION', 'v5');
```

## Current Slots

| Slot | Purpose |
|------|---------|
| v0 | Reserved for experiments |
| v1 | Reserved for experiments |
| v2 | Reserved for experiments |
| v3 | Reserved for experiments |
| v4 | Reserved for experiments |
| v5 | Current baseline (baked) |

## Notes

- Variants are for experimentation only. Once a design is chosen, bake it into the base styles and remove the variant rules.
- Do not document font comparisons here; final typography belongs in the base theme tokens.
