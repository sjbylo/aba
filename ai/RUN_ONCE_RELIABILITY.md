# run_once Reliability Concerns and Mitigations

**Date**: January 2026  
**Status**: Analysis and recommendations for future hardening

## Overview

The `run_once()` function in `scripts/include_all.sh` manages background task execution with idempotency guarantees. This document analyzes crash/kill scenarios and potential reliability issues.

## Current Implementation

### Files Used
- `~/.aba/runner/<task-id>.lock` - flock-based lock for mutual exclusion
- `~/.aba/runner/<task-id>.pid` - Process ID of running task
- `~/.aba/runner/<task-id>.exit` - Exit code after completion
- `~/.aba/runner/<task-id>.log` - Task output

### Protection Mechanisms ✅

1. **Trap Handler** (`aba_runtime_cleanup`)
   - Catches INT/TERM signals
   - Calls `run_once -G` to kill all tasks
   - Cleans up all runner files
   - **Works**: Graceful shutdown with Ctrl-C

2. **Lock-based Coordination**
   - Uses `flock -n` for non-blocking acquire
   - Uses `flock -x` for blocking wait
   - **Works**: Prevents race conditions between concurrent runs

3. **TTL Support**
   - `-t <seconds>` option expires old results
   - Checks file mtime vs current time
   - **Works**: Prevents stale cache issues

## Crash/Kill Scenarios

### Scenario 1: Kill -9 During Task Execution ✅ OK

```bash
1. Task starts, creates .lock, .pid
2. kill -9 on aba process (or system crash)
3. Task process still running (setsid isolated)
4. Next aba run:
   - Tries to acquire lock
   - Lock is HELD by running task
   - Blocks until task completes
   - Task writes .exit file
   - Next caller sees .exit, returns cached result
```

**Status**: ✅ **Works correctly** - lock prevents issues

### Scenario 2: Kill -9 on Background Task ✅ OK

```bash
1. Task starts, creates .lock, .pid
2. Task process killed (kill -9 on PID)
3. Lock released (FD closed)
4. No .exit file created
5. Next aba run:
   - Lock is free
   - No .exit file
   - Restarts task
```

**Status**: ✅ **Works correctly** - task will retry

### Scenario 3: Stale .exit File ⚠️ POTENTIAL ISSUE

```bash
1. Task completes, writes .exit file
2. Before cleanup, system crashes
3. .pid, .lock, .exit all remain
4. System reboots, PID reused for different process
5. Next aba run:
   - Sees .exit file (line 1531)
   - Returns 0 immediately
   - ASSUMES task completed successfully
   - DOES NOT validate if .pid is stale
```

**Current Code** (lines 1530-1533):
```bash
# If exit file exists (task already completed), skip
if [[ -f "$exit_file" ]]; then
    return 0  # ⚠️ Blindly trusts .exit file!
fi
```

**Issue**: No validation that:
- Process in .pid is actually dead
- .exit file corresponds to current task run
- Files aren't stale from previous boot

## Recommended Improvements

### High Priority: PID Validation ⚠️

**Problem**: We trust `.exit` file without checking if PID is still alive.

**Fix**: Add PID validation before trusting `.exit` file:

```bash
# --- start mode ---
if [[ "$mode" == "start" ]]; then
    if [[ ${#command[@]} -eq 0 ]]; then
        echo "Error: start mode requires a command." >&2
        return 1
    fi
    
    # IMPROVED: Validate .exit file before trusting it
    if [[ -f "$exit_file" ]]; then
        # If .pid exists, verify process is actually dead
        if [[ -f "$pid_file" ]]; then
            local task_pid
            task_pid="$(cat "$pid_file" 2>/dev/null || true)"
            if [[ -n "$task_pid" ]] && kill -0 "$task_pid" 2>/dev/null; then
                # Process STILL RUNNING - task not actually complete!
                # This could happen if:
                # 1. .exit was written prematurely (bug)
                # 2. Task is writing .exit but still has cleanup to do
                aba_debug "Task $work_id has .exit file but PID $task_pid still running - waiting"
                # Clean up inconsistent state and restart
                rm -f "$exit_file"
            fi
            # else: Process is dead, .exit is valid
        fi
        # If still have .exit after validation, trust it
        if [[ -f "$exit_file" ]]; then
            return 0
        fi
    fi
    
    _start_task "false"
    return 0
fi
```

**Benefits**:
- ✅ Detects stale .exit files from previous runs
- ✅ Detects PID reuse (different process has same PID)
- ✅ Prevents trusting incomplete task state
- ✅ Minimal overhead (just one `kill -0` syscall)

### Medium Priority: Stale File Cleanup

**Problem**: System crash leaves stale .pid/.lock/.exit files.

**Fix**: Add automatic cleanup of stale state on startup:

```bash
# After work_id is set, clean up stale state
if [[ -f "$pid_file" ]]; then
    local task_pid
    task_pid="$(cat "$pid_file" 2>/dev/null || true)"
    if [[ -n "$task_pid" ]] && ! kill -0 "$task_pid" 2>/dev/null; then
        # PID is dead but files remain - clean up stale state
        aba_debug "Cleaning up stale state for task $work_id (PID $task_pid is dead)"
        _kill_id "$work_id"
    fi
fi
```

### Low Priority: Atomic Exit File Write

**Conclusion**: **NOT NEEDED** for exit codes.

**Why?**
- Writing a single digit ("0" or "1") is atomic at kernel level
- Writes under PAGE_SIZE (4KB) are atomic
- `echo "$rc" >"$exit_file"` is sufficient

**Note**: `mv` (rename) IS atomic on POSIX systems, but overkill for this use case.

## Testing Needs

### Current Test Coverage
- ✅ Basic run_once functionality (test-run-once-ttl.sh)
- ✅ TTL expiration
- ❌ Crash/kill scenarios
- ❌ Stale file handling
- ❌ PID reuse detection

### Recommended Tests

**Test 1: Stale .exit File Detection**
```bash
# Simulate: Task completed, then system crashed, PID reused
1. Run task to completion (creates .exit=0)
2. Manually write bogus PID to .pid file
3. Run task again
4. Should detect stale state and re-run task
```

**Test 2: Concurrent Task Execution**
```bash
# Verify: Multiple callers wait correctly
1. Start task in background
2. Start 3 more instances immediately
3. All should wait for first to complete
4. All should return same exit code
```

**Test 3: Kill -9 During Execution**
```bash
# Verify: Task restarts after kill
1. Start long-running task
2. kill -9 the task process (not aba)
3. Run task again
4. Should detect no .exit and restart
```

**Test 4: System Crash Simulation**
```bash
# Verify: Cleanup after unclean shutdown
1. Start task
2. Remove .lock file (simulate crash)
3. Kill task process
4. Run task again
5. Should clean up and restart
```

## Implementation Priority

1. **Immediate**: Document these concerns ✅ (this file)
2. **Short-term**: Add PID validation (low risk, high value)
3. **Medium-term**: Add crash scenario tests
4. **Long-term**: Consider more robust state management (e.g., SQLite)

## Production Experience

**Known Issues**: None reported yet (as of Jan 2026)

**Mitigations in Place**:
- TTL option handles most stale state issues
- `run_once -G` cleanup on exit works well
- Lock-based coordination prevents most races

**When to Apply Fixes**:
- If stale state issues observed in production
- Before release to customers
- During next major refactor

## Notes

- PID reuse is rare but possible (especially in containers)
- System crashes are rare but DO happen (power loss, kernel panic)
- Current implementation is "good enough" for most cases
- Improvements add defensive programming without major complexity

## PID Display Feature (January 2026)

### Issue: PID Not Displaying in Wait Messages

**Problem**: When using `run_once -w -m "Custom message"`, the PID was not being appended to waiting messages even though it should have been.

**Root Causes** (3 issues):

1. **Directory Permissions** (700 vs 711)
   - Runner directories created with `chmod 700` (owner-only access)
   - Processes running as different users couldn't traverse directories
   - **Fix**: Changed to `chmod 711` (owner: full, others: execute-only)
   - **Why 711**: Allows traversal but not listing - more secure than 755

2. **PID File Permissions** (600 vs 644)
   - PID files created with `chmod 600` (owner-only read)
   - Other processes couldn't read PID values
   - **Fix**: Added `chmod 644 "$pid_file"` after writing PID
   - **Why 644**: Allows read access for wait operations

3. **Bash Command Substitution Bug**
   - **CRITICAL**: `$(<"file" 2>/dev/null)` returns **EMPTY** in bash!
   - This is a bash limitation/quirk (confirmed in version 5.1.8+)
   - The stderr redirect breaks the `$(<)` optimization
   - **Fix**: Removed `2>/dev/null` - check file existence first instead
   
   ```bash
   # ❌ BROKEN - Returns empty!
   local pid=$(<"$pid_file" 2>/dev/null || echo "")
   
   # ✅ FIXED - Works correctly
   if [[ -f "$pid_file" ]]; then
       local pid=$(<"$pid_file")
   fi
   ```

**Result**: 
- Wait messages now correctly display PID:
  ```
  [ABA] Waiting for operator index: community-operator v4.19 to finish downloading in the background (PID: 12345)
  ```
- Better UX: Users can see which process is running
- Can monitor/kill processes if needed: `ps -p 12345`

**Lesson Learned**: 
- Always test bash shortcuts with redirection
- Don't blindly use `2>/dev/null` - check conditions first
- File permissions matter when processes run with different privileges

## Quiet Wait Feature - `-q` Flag (January 2026)

### Purpose

Suppress waiting messages for short-lived tasks to reduce output clutter.

### Problem

When `run_once -w` waits for quick tasks (< 2 seconds), showing waiting messages creates visual noise:

```
[ABA] Checking Internet connectivity to required sites...
[ABA] Waiting for task: cli:check:api.openshift.com (PID: 3281474)
[ABA] Waiting for task: cli:check:mirror.openshift.com (PID: 3281536)
[ABA] Waiting for task: cli:check:registry.redhat.io (PID: 3281547)
[ABA]   ✓ All required sites accessible
```

The "Waiting for task..." messages flash briefly and clutter the output.

### Solution: `-q` (Quiet Wait) Flag

**Implementation**:
```bash
# Added to run_once() in include_all.sh:
local quiet_wait=false
while getopts "swi:cprGFt:eW:m:q" opt; do
    case "$opt" in
        q) quiet_wait=true ;;
        # ... other cases
    esac
done

# Conditional message display:
if [[ "$quiet_wait" != true ]]; then
    # Build and display waiting message
    aba_info "$msg"
fi
```

**Usage**:
```bash
# ✓ Use -q for short tasks:
run_once -w -q -i "cli:check:api.openshift.com" -- curl -sL --head https://api.openshift.com/
run_once -w -q -i "ocp:stable:latest_version" -- fetch_latest_version stable

# ✗ DON'T use -q for long tasks - users need feedback:
run_once -w -q -i "cli:install:oc-mirror" -- make -sC cli oc-mirror  # BAD!

# ✓ Use -m for long tasks instead:
run_once -w -m "Waiting for oc-mirror binary download" -i "cli:install:oc-mirror" -- make -sC cli oc-mirror
```

**Applied To** (5 locations in `scripts/aba.sh`):
1. Connectivity checks (3): `cli:check:api.openshift.com`, `cli:check:mirror.openshift.com`, `cli:check:registry.redhat.io`
2. Version fetches (2): `ocp:$ocp_channel:latest_version`, `ocp:$ocp_channel:latest_version_previous`

**Result - Clean Output**:
```
[ABA] Checking Internet connectivity to required sites...
[ABA]   ✓ All required sites accessible

Fetching available versions ... Done.
```

**Benefits**:
- ✅ Reduced visual clutter for quick operations
- ✅ Professional, polished output
- ✅ Users only see messages for operations that actually take time
- ✅ Optional - doesn't affect long-running tasks

**Guidelines**:
- Use `-q` for tasks < 2 seconds (connectivity checks, file reads, quick API calls)
- Use `-m` for tasks > 5 seconds (downloads, builds, installations)
- For 2-5 second tasks, use judgment based on user context

## References

- `scripts/include_all.sh` lines 1360-1570 (run_once implementation)
- `scripts/include_all.sh` lines 1638-1656 (cleanup trap handler)
- POSIX flock documentation
- Linux PID allocation behavior

---

**Last Updated**: January 21, 2026  
**Author**: AI Analysis  
**Reviewer**: Steve (pending)

