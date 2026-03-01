# Session State

## Current goal
E2E test monitoring loop + framework fixes (10-point plan).

## Done this session
- **Cross-suite cleanup bug fix**: `_pre_suite_cleanup` now iterates ALL `*.cleanup`/`*.mirror-cleanup` files.
- **Mirror registration**: Added `e2e_register_mirror()` + `e2e_cleanup_mirrors()` to framework.sh.
- **Resource lifecycle rules 11-14**: Documented in framework.sh.
- **vCenter folder fix**: VC_FOLDER + GOVC_DATASTORE on disN after snapshot revert.
- **notify.sh deployment**: Permanently deployed via run.sh.
- **day2 + skopeo**: Added missing day2 calls after mirror load/sync, skopeo pre-checks.
- **Rules of engagement updated**: Fixed contradictory rule 11, added rules 16-17, documentation preference, resource lifecycle section.
- Committed `fad834b`, pushed to origin/dev.

## Next steps
- Commit rules-of-engagement updates when user approves.
- Monitor pools 1/2/3 per 10-point plan.

## Decisions / notes
- NO safety nets in suite_end() -- fix the suite (rule #5/16).
- SNO: shutdown only. Compact/Standard: must delete. Mirrors: uninstall.
- Always `aba day2` after `mirror load`/`sync` (rule 17).
- Prefer code comments over ai/ files for documentation.
