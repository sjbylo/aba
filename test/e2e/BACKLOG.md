# E2E Test Framework -- Backlog

## Pending

- [ ] **Default to parallel dispatch when pools exist.**
  Remove the `--parallel` flag requirement. When `pools.conf` exists (or `--create-pools` is used), default to parallel dispatch across all pools. Add `--sequential` (or `--single-pool`) escape hatch for debugging one suite at a time. Interactive mode (`-i`) would imply sequential.

- [ ] **Configurable retry delay, count, and cap across all execution functions.**
  `e2e_run` already supports `-r RETRIES BACKOFF` but the initial delay (5s) and max cap (40s) are hardcoded. Make these configurable per call, e.g. `e2e_run -r 3 1.5 --delay 30 --max-delay 120 "description" "cmd"`. Apply the same to `e2e_run_remote`, `e2e_run_must_fail`, and `e2e_run_must_fail_remote`. Useful for operations like `oc-mirror` where a port may need more time to be released.

- [ ] **Improve transparency / verbose logging of framework actions.**
  The test framework should make it much clearer what it is doing and what commands it is running at every step. Currently too much is hidden behind helpers and `2>/dev/null` redirects, making it hard to debug failures. Consider:
  - Print the actual shell command before executing it (not just the description) in `e2e_run`, `e2e_run_remote`, etc.
  - Add a `--verbose` / `-v` flag to `run.sh` that enables detailed command-level logging.
  - Show real-time SSH commands, rsync transfers, govc calls, and snapshot operations as they happen.
  - Remove or gate `2>/dev/null` on critical commands so errors aren't silently swallowed (e.g. the preflight SSH checks).
  - Log wall-clock duration of each step so slow operations are immediately visible.

- [ ] **Refactor run.sh -- it's getting too complex.**
  `run.sh` has grown organically: sequential vs parallel paths, per-pool clone-and-check loops duplicated in both paths, special-case filtering of clone-and-check, tmux dispatch with poll-wait, etc. Consider:
  - Extract the sequential dispatcher into `lib/sequential.sh` (mirror `lib/parallel.sh`).
  - Unify the per-pool clone-and-check loop (used in both parallel and sequential) into a shared helper.
  - Move tmux session management (create, attach, poll, cleanup) into a reusable function.
  - Simplify suite filtering (clone-and-check skip, coordinator-only detection) into one place.
  - Goal: `run.sh` main should be ~50 lines of high-level flow, not ~250 lines of interleaved logic.
