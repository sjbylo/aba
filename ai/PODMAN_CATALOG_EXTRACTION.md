# Podman-Based Catalog Extraction

**Date**: 2026-03-18
**Status**: Implemented on `dev`

## Summary

Replaced `oc-mirror list operators` with direct podman-based extraction from
Red Hat catalog container images. This eliminates the oc-mirror dependency for
operator listing, improves accuracy, and enables display name extraction.

## Motivation

- `oc-mirror list operators` occasionally returned stale data (e.g. wrong
  default channel for `confluent-for-kubernetes`)
- oc-mirror was a heavy dependency just for listing operators
- Display names were not available through oc-mirror's output
- oc-mirror's `/tmp` usage caused failures on Fedora (RAM-backed tmpfs)

## How It Works

1. `podman pull` the catalog image (e.g. `registry.redhat.io/redhat/redhat-operator-index:v4.21`)
2. `podman cp` the `/configs/` directory out of the container
3. Parse each operator directory for `olm.package` schema entries:
   - JSON catalogs: `jq` extraction from `catalog.json`
   - YAML catalogs: `awk`-based parsing of `catalog.yaml`
   - Generic fallback: scans all JSON files in unrecognised directory layouts
4. Extract operator name, display name, and default channel
5. Write sorted index to `.index/<catalog>-index-v<version>`

### Signature Verification

Catalog images use `--signature-policy` with `insecureAcceptAnything` (same as
oc-mirror's internal behaviour). A temporary policy file is created and cleaned
up after pull.

### Architecture Independence

FBC catalog content is byte-for-byte identical across all four architectures
(`amd64`, `arm64`, `ppc64le`, `s390x`). No arch-specific extraction needed.

## Files Changed

### Core extraction
- `scripts/download-catalog-index.sh` -- main entry point (renamed from
  `extract-catalog-index.sh`), handles podman pull/cp/parse, writes index
  file plus hidden `.expected-count` and `.done` metadata
- `scripts/download-catalogs-start.sh` -- starts background downloads
- `scripts/download-catalogs-wait.sh` -- waits for completion
- `scripts/download-and-wait-catalogs.sh` -- wrapper

### oc-mirror removal from catalog path
- `scripts/aba.sh` -- removed early oc-mirror download before catalog prefetch
- `scripts/prefetch-catalogs.sh` -- removed `run_once` wait for oc-mirror
- `tui/abatui.sh` -- removed oc-mirror wait block before ISC generation

### ISC generation
- `scripts/add-operators-to-imageset.sh` -- reads display name from index,
  adds as YAML comment with fuzzy redundancy filtering

### Cleanup
- `Makefile` -- `aba reset` now deletes `.index/`

## Index File Format

```
%-55s %-60s %s
operator-name          Display Name                    default-channel
```

Three whitespace-separated columns. Display name may be multi-word or `-` if
unavailable.

## End-of-Extraction Summary

When issues are detected (skipped directories or count mismatches), a summary
is printed:

```
Warning: Catalog extraction summary for redhat-operator v4.21:
  Extracted: 75/77 operators
  Skipped directories (could not parse):
    - some-operator-dir
```

Clean runs are silent.

## Testing

- `test/func/test-extract-catalog-index.sh` -- validates extraction against
  oc-mirror reference data for OCP 4.16-4.21 across all 3 catalogs
- `test/func/test-catalog-canary.sh` -- standalone canary that auto-detects
  available OCP versions (including pre-GA like 4.22), runs the production
  entry point, and checks: non-empty output, sane count, completeness
  (extracted vs. expected), format, and display name coverage
- E2E suites (`suite-mirror-sync`, `suite-airgapped-*`) exercise the full
  save/sync/load pipeline which uses the catalog extraction

### Canary in Cron

The canary script is designed for periodic automated runs:

```cron
0 6 * * 1  /path/to/aba/test/func/test-catalog-canary.sh >> /var/log/canary.log 2>&1
```

- Auto-detects new OCP versions (catches format changes before GA)
- Exit code 0/1 for easy alerting
- Cleans up after itself (no disk accumulation)

## Decisions

| Decision | Rationale |
|---|---|
| All-in on podman, no oc-mirror fallback | Simplifies code, podman extraction is more accurate |
| `insecureAcceptAnything` for pull | Matches oc-mirror's own behaviour |
| Hidden metadata files (`.done`, `.expected-count`) | Clean `.index/` listing |
| Generic JSON fallback for unknown dirs | Handles renamed files gracefully |
| Canary tests pre-GA catalogs | Early warning if format changes |
