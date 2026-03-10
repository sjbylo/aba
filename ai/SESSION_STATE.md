# Session State

## Current goal
TUI improvements: screenshots, operator search test, mirror/.index path fixes.

## Done this session
- Removed bogus 'aba doctor' from TUI error dialog (tui/abatui.sh)
- Added fallback commands to 5 cli/Makefile run-once.sh -w calls
- Added fallback commands to 4 ensure_*() download-wait calls in include_all.sh
- Fixed fresh-install basket bug: changed mirror/.index to .index in abatui.sh (2 lines)
- Created test-tui-basket.sh and test-tui-basket-fresh.sh
- Added test-tui-basket.sh to integration tests in run-all-tests.sh
- Added screenshots to test-tui-early-exit.sh, test-tui-basic.sh, test-tui-basket.sh, test-tui-basket-fresh.sh
- Added "Search Operator Names" test to test-tui-basket.sh (searches local-storage, verifies basket count increase)
- Fixed mirror/.index -> .index in 8 files (scripts, E2E tests, func tests)
- All tests pass: basket (18/18), wizard (31/31), basic (17/17), early-exit (6/6), fresh (21/21), basket-fresh (15/15)

## Next steps
- Commit and push all changes (awaiting user approval)
- Execute README updates plan

## Decisions / notes
- mirror/.index is a symlink to ../.index, only exists after make -C mirror .init
- Canonical catalog index location is .index/ (top-level)
- test-tui-basket-fresh.sh excluded from run-all-tests.sh (too slow, ~2.5 min)
