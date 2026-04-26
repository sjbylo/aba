# Session State

## Current goal
Release ABA v1.0.1.

## Done this session
- Audited CHANGELOG.md, RELEASE_BULLETS_1.0.1.md, ABA SPEC, E2E SPEC
- Updated CHANGELOG.md with 5 missing items
- Updated RELEASE_BULLETS_1.0.1.md with same + fixed 2 formatting typos
- Fixed release.sh to generate inline links in CHANGELOG headers
- Triple-checked all release script preconditions

## Next steps
- Commit 4 dirty files (CHANGELOG.md, ai/RELEASE_BULLETS_1.0.1.md, build/release.sh, ai/SESSION_STATE.md)
- Push to origin/dev
- Run: build/release.sh 1.0.1 "Bug fixes and reliability improvements"

## Decisions / notes
- No external contributors to credit
- Test-merge dev->main is clean
- Suites running: mirror-sync, create-bundle-to-disk, airgapped-local-reg, cluster-ops
- connected-public pending (will re-run with NTP assertion fix)
