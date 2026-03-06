# Session State

## Current goal
Renamed all `.installed`/`.uninstalled` marker files to `.available`/`.unavailable` across the codebase.

## Done this session
- Committed + pushed the "scripts-must-not-manage-markers" changes (commit dd29d8a)
- Renamed `.installed` -> `.available` and `.uninstalled` -> `.unavailable` in 17 files
- Confirmed `mirror/Makefile` is already a symlink to `templates/Makefile.mirror`
- Verified zero stale references remain (only historical docs + OpenShift API `installedCSV`)
- Pre-commit checks pass

## Next steps
- User to approve commit and push of the rename
- Continue with gotest directive after commit

## Decisions / notes
- Forward-only rename: no migration logic for existing mirror directories
- `scripts/day2-config-osus.sh` excluded: `installedCSV` is an OpenShift API field
- Historical docs (BACKLOG, E2E_FIXES_LOG, HANDOFF_CONTEXT) mention old names in done/history context
