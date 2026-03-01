# Session State

## Current goal
E2E test monitoring loop + framework fixes (10-point plan).

## Done this session
- **vCenter folder fix**: Added VC_FOLDER + GOVC_DATASTORE correction to `runner.sh` `_revert_dis_snapshot()` after SSH ready.
- **Cross-suite cleanup bug fix**: `_pre_suite_cleanup` now iterates ALL `*.cleanup` and `*.mirror-cleanup` files, not just `${SUITE}.cleanup`. This was the root cause of orphaned VMs in vCenter.
- **Mirror registration**: Added `e2e_register_mirror()` + `e2e_cleanup_mirrors()` to framework.sh, mirroring the cluster pattern.
- **Golden rules 11-14**: Documented resource lifecycle policy (SNO: shutdown; compact/standard: delete; mirrors: uninstall; OOB registry: never touch).
- **Suite mirror calls**: Added `e2e_register_mirror` to 3 suites (airgapped-local-reg, airgapped-existing-reg, mirror-sync).
- Deployed all changes to con1/2/3.
- Dispatched `connected-public` to idle pool 3.

## Next steps
- Commit and push when user approves.
- Monitor pools 1/2/3 per 10-point plan.
- Pool 1 VIP conflict should resolve once user deletes stale compact1 VMs from vCenter.

## Decisions / notes
- NO safety nets in suite_end() -- if a suite doesn't clean up, fix the suite (rule #5).
- SNO: shutdown only (small, useful for debugging). Compact/Standard: must delete.
- `_pre_suite_cleanup` is the crash recovery mechanism, not a substitute for proper suite cleanup.
- `~/.vmware.conf` on disN is NOT part of bundle/tar; runner.sh fixes it after snapshot revert.
