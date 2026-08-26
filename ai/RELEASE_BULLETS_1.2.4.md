# ABA v1.2.4 Release Highlights

- `aba day2` now auto-injects mirror registry credentials into imported or external clusters
- Mirror registry host RAM requirements documented (16+ GB recommended for RHOAI/AI workloads)
- oc-mirror image timeout auto-escalates on retries (40m → 50m → 60m, up to 90m)
- TUI upgrade dialog refreshes available versions without restart
- E2E dispatcher hardened against tmux session race conditions
- New `tools/skopeo-bulk.sh` for manual bulk image save/load
