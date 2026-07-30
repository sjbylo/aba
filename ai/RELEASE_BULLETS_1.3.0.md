# ABA 1.3.0 - Release Notes

Extra CLI bundling for air-gap, load preflight summary, and state externalization fix.

## New Features

- **Bundle optional extra CLIs for air-gap** — `aba save` and `aba bundle` download virtctl, kn, tkn, helm, opm, argocd, and roxctl (soft-fail). `aba load` installs extras on the disconnected side when present.

## Improvements

- **`aba load` shows transfer summary** — Before unpacking, prints what the transfer contains (OCP version, operator catalogs, registry type).
- **Bundle builds prune unused images** — Reclaims disk from prior builds before creating install bundles.

## Bug Fixes

- **Fix `externalize_cluster_state()` conditional sourcing** — Stale `machine_network` from aba.conf leaked into state.sh when normalize was conditionally skipped. Now both normalize functions are always sourced.
- **Fix stale transfer metadata on `aba load`** — Leftover ISC/metadata from a prior upgrade transfer caused false digest mismatches.
