# ABA 1.1.0 - Release Notes

TUI v2, vSphere preflight validation, externalized state management, and reliability improvements.

## New Features

- **TUI v2** — Complete interactive UI rewrite with wizard mode, operator browsing, ISO generation and advanced menu.
- **vSphere Preflight Validation** — Multi-layer pre-install checks (connectivity, auth, resources, privileges) with per-check `[OK]/[FAIL]` report. (@mateuszslugocki)
- **Externalized state management** — Mirror and cluster state persisted externally, enabling state-aware operations and directory recreation.
- **Pre-built operator catalog indexes** — Ship catalog indexes for instant operator browsing without network access.
- **Smart `starting_ip` default** — Auto-compute from machine network CIDR.

## Improvements

- Install script styled output with actionable error messages.
- CLI binaries rebuild automatically when OCP version changes.
- Quay password validation rejects dangerous characters.
- CLI flags (`--ntp`, `--dns`, etc.) target correct cluster with `--name`.
- Firewall port closed on registry uninstall.
- Hardened config editing against metacharacter corruption so any arbitrary value can be safely written to config files.

## Bug Fixes

- DNS misconfiguration is now fatal (no silent continue).
- CLI download race condition fixed.
- `set -e` crash patterns replaced across core scripts.
- Orphaned catalog containers prevented with EXIT trap.
- Platform toggle persists correctly to `aba.conf`.

## Community

- **Mateusz Slugocki** (@mateuszslugocki) — vSphere preflight validation feature.
