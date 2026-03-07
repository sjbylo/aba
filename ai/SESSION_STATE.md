# Session State

## Current goal
Stabilize E2E test suite via "gotest" directive (autonomous run/monitor/fix loop).

## Done this session
- Diagnosed pool-registry killed by nuclear podman cleanup; added `_ensure_pool_registry()`
- Removed redundant podman cleanup from `suite-create-bundle-to-disk.sh`
- Removed unrealistic `rm -rf ~/.oc-mirror` cache purges from airgapped suites
- Fixed GOVC_DATASTORE on con2/3/4; added conN vmware.conf patching to runner.sh
- Tested expand-home.service on golden VM (works: 200G→400G)
- Fixed ~/bin missing: cli/Makefile `| ~/bin` order-only prerequisite (universal fix)
- Fixed `aba: command not found` in setup_aba_from_scratch() (reinstall if missing)
- Added VM_DISK_EXTRA_GB=300 to config.env + disk expansion in clone_vm()
- All 4 pools running suites

## Next steps
- User reclones pool VMs from updated golden template (with expand-home.service)
- New clones auto-expand /home by 300GB on first boot
- Continue gotest monitoring

## Decisions / notes
- `/opt/pool-reg/` must NEVER be cleaned (pool registry data)
- Purging ~/.oc-mirror is unrealistic -- removed; VMs get larger /home instead
- cli/Makefile fix is universal (benefits all users, not just E2E)
- VM_DISK_EXTRA_GB=300 adds 300G to disk; expand-home.service grows /home on boot
