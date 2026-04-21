# Plan: Normalize Config Time Variables

## Goal

Make all time-related configuration variables consistent in naming and units.

## Current Inventory

### User-facing (`~/.aba/config`)

| Variable | Unit | Default | Suffix | Issue |
|----------|------|---------|--------|-------|
| `CATALOG_CACHE_TTL_SECS` | seconds | 43200 (12h) | `_SECS` | OK |
| `CATALOG_INDEX_DOWNLOAD_TIMEOUT_MINS` | minutes | 20 | `_MINS` | OK |
| `CATALOG_DOWNLOAD_TIMEOUT_MINS` | minutes | 20 | `_MINS` | Legacy alias -- should deprecate |
| `OC_MIRROR_IMAGE_TIMEOUT` | duration string | `30m` | none | Passed to oc-mirror; different format |

### Internal (`scripts/include_all.sh`)

| Variable | Unit | Default | Suffix | Issue |
|----------|------|---------|--------|-------|
| `ABA_CACHE_TTL` | seconds | 6000 | none | **Missing `_SECS` suffix** |

### E2E only (`test/e2e/config.env`)

| Variable | Unit | Default | Suffix | Issue |
|----------|------|---------|--------|-------|
| `SSH_WAIT_TIMEOUT` | seconds | 300 | none | No unit suffix |
| `VM_BOOT_DELAY` | seconds | 8 | none | No unit suffix |
| `GOLDEN_MAX_AGE_HOURS` | hours | 24 | `_HOURS` | OK |
| `OPERATOR_WAIT_TIMEOUT` | seconds | 1800 | none | **Unused in code** |

## Proposed Changes

### 1. Rename `ABA_CACHE_TTL` -> `ABA_CACHE_TTL_SECS`

- Location: `scripts/include_all.sh` line 974 (definition + all usages)
- Keep backward compat: `ABA_CACHE_TTL_SECS="${ABA_CACHE_TTL_SECS:-${ABA_CACHE_TTL:-6000}}"`

### 2. Deprecate `CATALOG_DOWNLOAD_TIMEOUT_MINS`

- Already a fallback in `include_all.sh` line 2125
- Add a deprecation warning when it's set but `CATALOG_INDEX_DOWNLOAD_TIMEOUT_MINS` isn't
- Remove the fallback in a future release

### 3. Remove unused `OPERATOR_WAIT_TIMEOUT`

- Defined in `test/e2e/config.env` but never referenced in any `.sh` file
- Just remove it from `config.env`

### 4. Document `OC_MIRROR_IMAGE_TIMEOUT`

- This uses oc-mirror's native duration format (`30m`, `1h`, etc.)
- Different from the seconds/minutes pattern but correct for its purpose
- Add a comment in `~/.aba/config` template noting it uses Go duration syntax

### 5. Consider standardizing on minutes for user-facing config

- User-facing variables: use **minutes** (more human-friendly)
- Internal variables: convert to seconds in code
- Convention: always include `_MINS` or `_SECS` in the variable name
- This is a longer-term naming convention change; not urgent

## Decision Needed

Should all user-facing config use **minutes** consistently (converting to seconds internally), or keep the current mixed approach with unit suffixes in the names? Either is viable; suffixes are less disruptive.
