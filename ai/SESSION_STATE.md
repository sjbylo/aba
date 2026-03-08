# Session State

## Current goal
Stabilize E2E test suite -- fix plan_tests mismatches, add explicit end-of-suite cleanup blocks, fix audit gaps, add disk usage checks.

## Done this session
- Synced `plan_tests` with `test_begin` in all 10 suites (verified all in sync)
- Added explicit `test_begin "Cleanup: ..."` blocks at end of suites that were missing them
- Fixed 5 audit gaps (missing uninstall/unregister/delete in cleanup blocks)
- Made all cleanup delete/uninstall commands conditional (check dir exists first)
- Added `/home` disk usage check (< 10GB) after every cleanup block in all 7 suites with resources
- Fixed suite-config-validation.sh: replaced `aba -d mirror install 2>/dev/null || true` with `aba -d mirror mirror.conf`
- Removed `rm -rf mymirror` from suite-mirror-sync.sh to allow cleanup block to handle it
- Added new E2E Golden Rule #21 (explicit end-of-suite cleanup mandatory) to 3 rule files

## Next steps
- Commit and push these changes
- Run pre-commit checks
- Queue affected suites for testing on pools

## Decisions / notes
- Cleanup commands are conditional: `if [ -d X ]; then aba --dir X delete; else echo already removed; fi`
- Disk check uses `df /home --output=used -BG` and fails if > 10GB used after cleanup
- EXIT trap and `_pre_suite_cleanup` are safety nets only -- explicit cleanup is the primary path
