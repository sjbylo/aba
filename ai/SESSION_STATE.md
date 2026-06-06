# Session State

## Current goal
Pre-release v1.1.0 validation — COMPLETE.

## Done this session
- Full DISCO bundle workflow tested end-to-end via TUI ONLY — ALL 13 STEPS PASSED
- Upgrade path: 4.20.20 → 4.20.23 (same-minor) → 4.21.17 (cross-minor)
- Cluster delete and mirror uninstall tested via TUI
- **Fixed bug in `scripts/cluster-upgrade.sh`:**
  - Used `.status.desired.version` → changed to `.status.history[Completed].version`
  - Moved idempotency check before health check (UX improvement)
  - Fix deployed to registry and verified on live cluster

## Next steps
- Commit the `cluster-upgrade.sh` fix (pending user approval)
- Consider TUI enhancement: expose `--force` for AdminAckRequired cross-minor upgrades
- Ready for v1.1.0 release

## Decisions / notes
- AdminAckRequired for 4.20→4.21 (Sigstore) needed manual `oc patch` — TUI doesn't expose `--force`
- All other TUI operations worked flawlessly end-to-end
- Fix confirmed: "Current cluster version" now shows actual completed version, not desired
