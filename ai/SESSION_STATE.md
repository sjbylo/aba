# Session State

## Current goal
Quay resource check + clean working-dir fix.

## Done this session
- Committed+pushed 5 commits (core fixes, E2E tests, TUI help, Makefile+localhost, TUI settings)
- Added reg_check_quay_resources() — aborts if <4 vCPUs or <8GB RAM
- Added aba clean removal of save/working-dir and sync/working-dir

## Next steps
- Commit and push Quay resource check + clean fix when user approves

## Decisions / notes
- Quay needs 4 vCPUs and 8GB RAM minimum
- Check applies to both local and remote installs
- aba clean now removes oc-mirror working-dir (can get corrupted)
