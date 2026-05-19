# Session State

## Current goal
Shipped Catalog Index Files -- plan finalized, awaiting user approval to implement.

## Done this session
- Discovered consumers don't check `.done` -- only `-s .index/X`
- Discovered TTL re-download is broken (script's .done skip defeats run_once TTL)
- Simplified to populate-from-shipped + atomic rename + remove .done
- Chose `catalog-indexes/` as top-level dir (not in bundle, useful for connected users)
- Eliminated .gitignore and backup.sh changes entirely
- Added refresh script (`tools/refresh-catalog-indexes.sh`) to keep indexes fresh between releases

## Next steps
- Get user approval on the final plan
- Implement (5 todos: populate-fn, atomic-download, seed-shipped, refresh-script, test)

## Decisions / notes
- `catalog-indexes/` = top-level, git-tracked, NOT in bundle (backup.sh untouched)
- Populate copies `catalog-indexes/X` -> `.index/X` on init if live doesn't exist
- No `.done` file -- run_once is sole gatekeeper; fixes latent TTL re-download bug
- Atomic mv: write to `.downloading` temp, rename when complete
- Refresh script: downloads, verifies (canary-style), commits, optionally moves release tag
- Zero consumer changes, zero .gitignore changes, zero backup.sh changes
- Plan file: `~/.cursor/plans/baked_catalog_indexes_02fc9df9.plan.md`
