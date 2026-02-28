# Session State

## Current goal
Monitoring E2E test suites, fixing bugs, preparing for full rerun.

## Done this session
- Static tmux session name (`e2e-suite`) on all conN hosts -- tested and working
- Fixed live dashboard: single-SSH approach eliminates connection teardown race
- Fixed BM simulation in suite-create-bundle-to-disk: runs on internal bastion
- Added detailed comments to both BM tests (create-bundle-to-disk + mirror-sync)
- Centralized NTP_SERVER and DEFAULT_GATEWAY in config.env
- Eliminated last hardcoded IPs from suites and config-helpers

## Next steps
- Wait for pools 1/2 to finish (con1 stuck at interactive prompt)
- Commit and push all changes
- Redeploy to all pools and rerun all suites

## Decisions / notes
- Two BM tests kept for defense-in-depth (sync perspective vs bundle-load perspective)
- BM test needs registry access: mirror-sync runs from con, create-bundle-to-disk from dis
- Gate files: .bm-message (phase 1) and .bm-nextstep (phase 2) control the two-step flow
