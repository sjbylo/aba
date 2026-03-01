# Session State

## Current goal
Add CLI options, fix collision, create Docker tests, document ABA architecture.

## Done this session
- Added `--vendor <auto|quay|docker>` and `--reg-port <number>` CLI options.
- Fixed `-P` collision: `--reg-port` is long-form only.
- Updated help text, suite, and cleanup test to use new flags.
- Created `test/func/test-e2e-cleanup.sh` (ALL 14 TESTS PASSED).
- Created `test/func/test-docker-registry.sh` (3 tests: localhost, remote, defaults).
- Documented ABA Connected->Bundle->Disconnected architecture in code comments.
- Fixed: removed conN/disN references from ABA core comments (user-facing code).
- Documented notification improvements as backlog issue #13.

## Next steps
- Run `test/func/test-docker-registry.sh` on an idle pool to verify.
- Run pre-commit checks, then user to approve commit+push.

## Decisions / notes
- conN/disN are E2E nomenclature only -- never use in ABA core code/comments.
- disN has NO INTERNET by design. All artifacts must be in the ABA bundle.
- No skip/fallback in test suites. Documentation as code comments, not ai/ files.
