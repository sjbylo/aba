# ADR-002: run_once() for task management

## Status
Accepted

## Context
ABA needs to coordinate long-running background tasks (CLI downloads, catalog
index downloads) across multiple Make targets and script invocations. Make
tracks file dependencies but cannot express "this download started 30 seconds
ago in another process -- wait for it instead of starting a second one."

## Decision
`run_once()` provides task deduplication, mutual exclusion (flock), and a
"start early, wait later" pattern. State lives in ~/.aba/runner/<id>/.

run_once complements Make -- it does not replace it. Make tracks file-based
dependencies. run_once tracks non-file task completion (downloads, connectivity
checks, catalog fetches).

## Consequences
- Two state systems: Make markers (in-tree) and run_once state (~/.aba/runner/)
- If a file that Make produced is deleted but run_once wrapped the task,
  run_once still thinks the task is done. Cleanup must pair `run_once -r`
  with file removal.
- No automatic state cleanup on Ctrl-C. `aba reset` is the explicit full
  reset. Failed tasks are cleaned on next `aba` start via `run_once -F`.
- Only run_once() may access ~/.aba/runner/ -- no hand-rolled locks or PIDs
