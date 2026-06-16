# run_once Validation Race Condition Fix

## Problem

When multiple processes call `ensure_*()` functions simultaneously (e.g., 3 parallel catalog downloads all calling `ensure_oc_mirror()`), a race condition in the validation logic could cause failures with the error:

```
[ABA] Error: Failed to install oc-mirror:
```

Even though oc-mirror was actually installed successfully (exit code 0).

## Root Cause

The self-healing validation logic in `run_once()` had a race condition:

1. Process acquires lock for validation
2. **Immediately releases lock** (`exec 9>&-` at line 1673)
3. Tries to call `_start_task()` to run validation
4. `_start_task()` tries to re-acquire the lock
5. Another waiting process can grab the lock before step 4
6. Validation fails with "Task not started and no command provided"

## The Fix

**File**: `scripts/include_all.sh` (lines 1664-1698)

**Change**: Keep the lock held continuously during validation:

```bash
# OLD CODE (race condition):
if flock -n 9; then
    exec 9>&-                    # ❌ Released lock too early!
    aba_debug "Running validation..."
    _start_task "false"          # Tries to re-acquire lock (conflict!)
    wait $!
    exit_code="$(cat "$exit_file" 2>/dev/null || echo 1)"
fi

# FIXED CODE (no race):
if flock -n 9; then
    aba_debug "Running validation..."
    
    # Run validation directly while holding lock
    : >"$log_out_file"
    : >"$log_err_file"
    
    "${command[@]}" >"$log_out_file" 2>"$log_err_file"
    local validation_rc=$?
    echo "$validation_rc" > "$exit_file"
    exit_code="$validation_rc"
    
    exec 9>&-                    # ✅ Release lock AFTER validation
fi
```

## Key Changes

1. **Don't release lock early** - Keep lock held during entire validation
2. **Run command directly** - Don't call `_start_task()` (which would try to re-acquire lock)
3. **Synchronous execution** - Validation runs synchronously while holding lock
4. **Release after completion** - Lock released only after validation completes

## Testing

### Test Results - OLD CODE (Before Fix)

```
Attempt 1: FAILED - "Task not started and no command provided"
Attempt 2: FAILED - "Task not started and no command provided"  
Attempt 3: PASSED (with warning "wait: pid ... is not a child of this shell")
```

**Failure rate: 67% (2/3 failed)**

### Test Results - FIXED CODE (After Fix)

```
Attempt 1: PASSED
Attempt 2: PASSED
Attempt 3: PASSED
Attempt 4: PASSED
Attempt 5: PASSED
```

**Success rate: 100% (5/5 passed with clean state)**

## Tests

- **`test/func/test-self-heal-validation.sh`** - Tests self-healing validation logic
- **`test/func/test-run-once-parallel-validation.sh`** - Tests parallel validation (NEW)

Run tests:
```bash
test/func/test-self-heal-validation.sh
test/func/test-run-once-parallel-validation.sh
```

## Impact

This fix resolves:
- ✅ Parallel catalog downloads failing intermittently
- ✅ "Failed to install oc-mirror" errors when oc-mirror was actually installed
- ✅ Race conditions in `ensure_*()` functions
- ✅ Empty error messages from `get_task_error()`

## Related Issues

- Also fixed: Error file handling in `reg-sync.sh`, `reg-save.sh`, `reg-load.sh` (use `mv` instead of `cp` to prevent old error files from being re-detected)
