# Session State

## Current goal
Fixed regression test escaping bug in suite-mirror-sync.sh; renamed markers to .available/.unavailable.

## Done this session
- Committed + pushed "scripts-must-not-manage-markers" changes (dd29d8a)
- Renamed .installed -> .available and .uninstalled -> .unavailable across 17 files (a57cd7f)
- Fixed regression test: removed backslash escaping before parentheses in `bash -c` single-quoted block

## Next steps
- Commit + push the regression test fix
- Deploy to pools and continue gotest

## Decisions / notes
- `\(` inside single quotes in `bash -c '...'` is literal, breaking `<(...)` process substitution
- Fix: use unescaped `<(normalize-aba-conf)` since single quotes protect from eval
