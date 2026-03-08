# Session State

## Current goal
Fix Makefile.mirror dependency and ordering issues (plan: "Fix Makefile dependencies").

## Done this session
- Added `mirror-registry` back as order-only prereq of `.available`
- Fixed `clean` ordering: symlink deletion moved to last line (after run-once.sh calls)
- Fixed `reset` ordering: run-once.sh calls moved before `make clean`; removed redundant marker reset
- Removed `2>/dev/null || true` from all 4 run-once.sh calls
- Previous uncommitted: `.rpmsext` moved to order-only for `.available`, added to `register` target
- Tested on bastion: `make clean` then `make install` correctly re-extracts mirror-registry binary
- Pre-commit checks pass
- Added "clean vs reset" documentation section to ai/RULES_OF_ENGAGEMENT.md

## Next steps
1. Commit and push (awaiting user approval)
2. Deploy to registry4 and test `make -C mirror install` standalone
3. User re-running test1 on registry2; may need to address `save load` / `reg_detect_existing` issue separately

## Decisions / notes
- `mirror-registry` as order-only: avoids timestamp-triggered reinstall after clean
- `run-once.sh -r` exits 0 silently -- no reason for error suppression
- `clean` = mid-workflow restart (derived files); `reset` = distclean (full restore)
- SSH hang to registry4 during real test was unrelated (stale connection)
