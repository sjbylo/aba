# ABA 1.0.0 - Release Notes

Stability and reliability improvements.

## New Features

- **Unified progress spinner** -- All long-running operations (cluster startup/shutdown, mirror save/load/sync, day2 configuration) now show a live spinner with elapsed time and maximum timeout, so you always know ABA is working and how long to wait.
- **Improved VM annotations** -- VMware VM annotations now show richer metadata (cluster name, role, network, install date, console/API URLs). Added `virsh desc` annotations for KVM VMs -- viewable via `govc vm.info` or `virsh desc`.
- **Configurable mirror age (`OC_MIRROR_SINCE`)** -- Control how far back oc-mirror looks for changes via `~/.aba/config`. Set a far-back date to force full mirror archives instead of differential.

## Improvements

- **Cleaner output** -- Day2 operations show condensed progress; spinner displays max timeout; startup curl noise suppressed.

## Bug Fixes

- **`reg-save.sh` ignoring `data_dir`** -- Save operations now respect the `data_dir` setting in `mirror.conf`, directing caches to the configured partition instead of filling up `$HOME`.
- **Reliable `aba delete`** -- Verified VM destruction, proper cleanup of already-deleted clusters (exits 0 on no-op), and works correctly even after `aba clean`.
- **Hardened shutdown** -- 40-minute timeout with automatic abort on failure; exit code properly propagated.
- **ESXi standalone support** -- Proper `VC_FOLDER` fallback and ESXi detection for standalone hosts (no vCenter).
- **`GOVC_RESOURCE_POOL` path duplication** -- Removed hardcoded `resourcePool` from example install-configs; simplified placeholder resolution.
