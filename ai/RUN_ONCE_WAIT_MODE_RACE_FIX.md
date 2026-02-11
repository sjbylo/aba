# run_once Wait-Mode Start Race Condition Fix

**Date**: February 2026
**Commit**: 19666af

## Problem

When multiple processes concurrently call `run_once -w -i <same-task> -- <command>`
(e.g., 3 parallel catalog downloads all calling `ensure_oc_mirror()`), a race
condition in the wait-mode "start" path caused false failures:

```
[ABA] Error: Failed to install oc-mirror:
```

With no error details (empty error log), even though the task actually succeeded.

## Root Cause

In `run_once()` wait mode, the "start task" path (when no task is running):

1. Process A: `flock -n 9` succeeds (probe lock acquired)
2. Process A: `exec 9>&-` — **RELEASES** probe lock
3. Process B: `flock -n 9` succeeds (slips through the gap!)
4. Process B: `exec 9>&-` — releases lock
5. Process A: `_start_task "true"` — re-acquires lock, starts task
6. Process B: `_start_task "true"` — can't get lock, returns 0
7. Process B: `wait $!` — returns immediately ($! is unset/stale)
8. Process B: reads exit_file — doesn't exist yet — defaults to exit_code=1 — **FALSE FAILURE**

The gap between releasing the probe lock (step 2) and re-acquiring it inside
`_start_task` (step 5) allowed concurrent callers to slip through.

## The Fix

Two changes to `scripts/include_all.sh`:

### Change 1: `_start_task()` accepts `lock_held` parameter

```bash
_start_task() {
    local is_fg="$1"
    local lock_held="${2:-false}"       # NEW

    if [[ "$lock_held" != "true" ]]; then  # NEW
        exec 9>>"$lock_file"
        if ! flock -n 9; then
            exec 9>&-
            return 0
        fi
    fi                                  # NEW
    # ... rest unchanged
```

### Change 2: Wait mode keeps probe lock held

```bash
if flock -n 9; then
    # Keep FD 9 open -- lock transfers to _start_task's subshell
    if [[ ${#command[@]} -eq 0 ]]; then
        echo "Error: Task not started and no command provided." >&2
        exec 9>&-   # Release lock on error path
        return 1
    fi
    _start_task "true" "true"   # Pass lock_held=true
    wait $!
```

The probe lock stays held continuously. `_start_task` skips re-acquisition
when `lock_held=true`. The lock transfers to the background subshell via
FD 9 inheritance, same as before.

### What doesn't change

- **Start mode** (line 1603): `_start_task "false"` — no prior lock, acquires its own
- **Wait mode "wait" path**: Uses `flock -x` for blocking — unchanged
- **Validation path**: Runs synchronously inline, doesn't use `_start_task` — unchanged

## Lock Pattern Summary

```
Pattern                      | Lock Held By           | Via _start_task? | Correct?
start mode (fire-and-forget) | _start_task acquires   | Yes              | Yes (unchanged)
wait mode (start path)       | Caller holds, passes   | Yes (lock_held)  | Yes (FIXED)
wait mode (wait path)        | flock -x blocking      | No               | Yes (unchanged)
validation                   | Caller holds inline    | No               | Yes (unchanged)
```

Design principle: "whoever acquires the lock must either hold it through the
protected section, or pass it cleanly to a child process."

## Testing

**Test**: `test/func/test-run-once-wait-start-race.sh`

Before fix: 8/10 iterations had false failures (race confirmed).
After fix: 0/40 failures across all test iterations (10+10+20).

## Related: Download-Before-Install Bug

This fix also revealed a separate bug: `ensure_oc_mirror()` was extracting
tarballs before downloads completed (after `cli reset -f`). The oc-mirror
tarball (125MB, ~9s download) was partially written when `make -sC cli oc-mirror`
tried to extract it, causing "gzip: unexpected end of file".

Fixed by adding `run_once -q -w -i "cli:download:oc-mirror"` to
`ensure_oc_mirror()`. See `CLI_ENSURE_ANALYSIS.md` for details.

## Related: Logical Download Task Naming

The download task IDs were refactored from tarball filenames
(`cli:download:oc-mirror.rhel9.tar.gz`) to logical tool names
(`cli:download:oc-mirror`). This keeps Makefile implementation details
(tarball names, RHEL versions) out of the ensure functions.

See `CLI_ENSURE_ANALYSIS.md` for the full Makefile refactor details.
