# ADR-017: Multi-value image_source for multi-mirror clusters

## Status
Proposed

## Context
ADR-012 merged `int_connection` and `mirror_name` into a single `image_source`
field in `cluster.conf`.  Today `image_source` is a scalar — it can be
`direct`, `proxy`, or a single mirror directory name (default `mirror`).

ABA's `day2.sh` already handles multi-mirror scenarios defensively: when it
detects CatalogSources from a different registry, it suffixes its own
CatalogSource names, merges CA keys (instead of overwriting), deduplicates,
and merges pull-secret credentials.  This works correctly.

However, there is no way to **declaratively** associate multiple mirrors with
one cluster.  Today, to integrate a second mirror you must either:

1. Create a second cluster directory via `aba import --image-source mm2` — an
   ugly workaround that makes it look like two clusters when it's really one.
2. Manually copy a cluster dir and change `image_source` — fragile.

Use cases:

- **OCP installed from mirror A, operators on mirror B**: Common in
  enterprises where platform images and operator images live on different
  registries (different teams, different air-gap boundaries).
- **Vendor-installed OCP with embedded mirror**: The OVE or another installer
  provides its own mirror.  The user adds their ABA mirror for additional
  operators.  `day2` must not clobber the vendor's CatalogSources.
- **Enclave mirrors**: Multiple enclaves each host a subset of operators.
  A cluster needs all of them.

## Decision
Extend `image_source` to accept a comma-separated list of mirror directory
names:

```conf
# Single mirror (unchanged, backward compatible):
image_source=mirror

# Multiple mirrors:
image_source=mirror,mm2,enclave3

# Non-mirror modes (unchanged):
image_source=direct
image_source=proxy
```

The **first entry** is the primary mirror used during initial cluster
installation (install-config, ISO generation).  All entries are used by
`day2`.

## Implementation sketch

### normalize-cluster-conf
- Parse `image_source` into an array (split on comma).
- Emit `image_source` (full comma-separated string) for backward compat.
- Emit `image_source_primary` (first entry) for install-config generation.
- Emit `image_source_list` (space-separated) for iteration in scripts.
- `image_source_is_mirror()` returns true if primary is not `direct`/`proxy`.

### day2.sh
- Loop over `$image_source_list`:
  ```bash
  for _mirror in $image_source_list; do
      regcreds_dir=$HOME/.aba/mirror/$_mirror
      source <(normalize-mirror-conf)
      # Apply CA, CatalogSources, IDMS/ITMS, pull-secret for this mirror
  done
  ```
- The existing multi-mirror detection stays — it handles mirrors ABA doesn't
  know about (vendor mirrors, external mirrors not in `image_source`).

### CLI
- `--mirror-name mm2` on an existing cluster **appends** to `image_source`
  (if not already present) rather than replacing.
- `--image-source mm2` still replaces the whole value (escape hatch).
- New: `aba day2 --mirror-name mm2` could be a shortcut that temporarily
  overrides `image_source` for a single day2 run without modifying
  `cluster.conf`.

### Symlinks: mirror and regcreds

Today, `make init` in a cluster directory creates:
- `mirror` → `../<image_source>` (single symlink to the mirror dir)
- `regcreds` → `~/.aba/mirror/<image_source>` (single symlink to credentials)

**Single mirror (unchanged):** When `image_source` has one entry, `mirror`
and `regcreds` stay exactly as they are today — direct symlinks.  No new
directories, no behavioral change.

**Multiple mirrors only:** When `image_source` has >1 entry, `make init`
creates subdirectories:

```
cluster/
  mirrors/
    mirror  -> ../../mirror           # primary
    mm2     -> ../../mm2              # secondary
  regcreds/
    mirror  -> ~/.aba/mirror/mirror   # primary creds
    mm2     -> ~/.aba/mirror/mm2      # secondary creds
  mirror    -> mirrors/mirror         # backward-compat: primary mirror
  regcreds  -> regcreds/mirror        # backward-compat: primary creds
```

The top-level `mirror` and `regcreds` symlinks point through to the primary
mirror's entries, so all existing scripts that reference `mirror/` or
`regcreds/` continue to work unchanged.  Only `day2.sh` iterates over
`mirrors/*/` and `regcreds/*/` to apply all mirrors.

### install-config generation
- Uses `image_source_primary` (first entry) — unchanged behavior.
- install-config only references one mirror (OCP installer limitation).

### TUI
- Settings panel shows all attached mirrors.
- "Attach Mirror" action appends to the list.
- "Detach Mirror" action removes from the list.

## Consequences
- Backward compatible: single-value `image_source` works identically.
  The `mirror` and `regcreds` symlinks behave exactly as today.
- Eliminates the "second cluster directory" workaround for multi-mirror.
- `cluster.conf` becomes the single source of truth for all mirrors.
- The defensive multi-mirror detection in `day2.sh` remains for the
  external-mirror case (mirrors ABA doesn't manage).

## Migration
- No migration needed — existing single-value `image_source` is valid.
- Users adding a second mirror would use `--mirror-name mm2` which appends.

## References
- ADR-012: Merge int_connection and mirror_name into image_source
- BACKLOG: "Multi-value image_source for multi-mirror clusters"
- `scripts/day2.sh`: Multi-mirror detection, CA merge, CS suffixing
- `test/e2e/suites/suite-cluster-ops.sh`: Test 9b (simulated) and 9d (real)
