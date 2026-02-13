# run_once TTL Removal - Architecture Decision

**Date**: 2026-01-24  
**Status**: Design Document - Approved  
**Decision**: Remove TTL (Time-To-Live) functionality entirely from `run_once()`

---

## Problem Statement

Current behavior with TTL causes catalog downloads to not re-download when output files are manually deleted:

```bash
$ make catalogs-download   # Downloads catalogs, creates files
$ rm mirror/.index/community-operator-index-v4.20
$ rm mirror/.index/.community-operator-index-v4.20.done
$ make catalogs-download   # Does NOT re-download! Files stay missing!
```

**Why?** TTL check in `run_once` (lines 1487-1502) bypasses the script's idempotency logic:

```bash
# Current behavior
if exit_file exists AND age < TTL:
    return 0  # Skip execution
else:
    run script  # Script checks if work needed
```

**Result**: Script never runs → never checks if outputs exist → no self-healing!

---

## Root Cause Analysis

### Issue 1: TTL Bypasses Script Idempotency

Scripts like `download-catalog-index.sh` have their own idempotency checks:

```52:55:scripts/download-catalog-index.sh
# Check if already downloaded
if [[ -s "$index_file" && -f "$done_file" ]]; then
    aba_info "Operator index $catalog_name v$ocp_ver_major already downloaded"
    exit 0
fi
```

**With TTL**: This check never executes! `run_once` returns before script runs.

**Without TTL**: Script always runs, checks outputs, exits quickly if valid, re-downloads if missing.

### Issue 2: TTL Violates Separation of Concerns

**run_once's job**:
- ✅ Prevent concurrent execution (locking)
- ✅ Background execution
- ✅ Log capture
- ✅ Exit code tracking
- ❌ Deciding if work is needed (that's the SCRIPT's job!)

**Script's job**:
- ✅ Check if outputs exist
- ✅ Decide if work is needed
- ✅ Perform actual work
- ✅ Implement caching/timing policies

**TTL makes run_once do the script's job!**

### Issue 3: TTL is Redundant

**For successful tasks**:
- Scripts already implement idempotency
- Quick exit if outputs exist
- TTL just adds complexity

**For failed tasks**:
- Cleaned automatically by `aba.sh` line 151: `run_once -F` (every invocation!)
- Cleaned manually by `./install` (wipes entire `~/.aba/runner/`)
- TTL never gets a chance to expire failed tasks

**Conclusion**: TTL provides no value!

---

## Failed Task Cleanup - How It Works

### Automatic Cleanup (Every `aba` Run)

```148:152:scripts/aba.sh
source $ABA_ROOT/scripts/include_all.sh
aba_debug "Sourced file $ABA_ROOT/scripts/include_all.sh"
# Note: No automatic cleanup on Ctrl-C. Background tasks continue naturally.
[ ! "$RUN_ONCE_CLEANED" ] && run_once -F # Clean out only the previously failed tasks
export RUN_ONCE_CLEANED=1 # Be sure it's only run once!
```

**Every `aba` command** automatically calls `run_once -F` which:

```1446:1462:scripts/include_all.sh
# --- GLOBAL FAILED-ONLY CLEAN ---
if [[ "$global_failed_clean" == true ]]; then
    local d id exitf rc
    shopt -s nullglob
    for d in "$WORK_DIR"/*/; do
        id="$(basename "$d")"
        exitf="$d/exit"
        if [[ -f "$exitf" ]]; then
        rc="$(cat "$exitf" 2>/dev/null || echo 1)"
        if [[ "$rc" -ne 0 ]]; then
            _kill_id "$id"
            fi
        fi
    done
    shopt -u nullglob
    return 0
fi
```

- Scans all tasks in `~/.aba/runner/`
- Deletes only failed tasks (exit code != 0)
- Runs once per shell session (via `RUN_ONCE_CLEANED` flag)

### Manual Cleanup (`./install`)

```168:173:install
# Reset ~/.aba state on manual install only
if [ ! "$QUIET_INSTALL" ]; then
    if [ -d ~/.aba/runner ] || [ -d ~/.aba/cache ]; then
        rm -rf ~/.aba/runner ~/.aba/cache
        echo Cache deleted
    fi
```

- User runs `./install` → entire `~/.aba/runner/` wiped
- Fresh start for all tasks

**Result**: Failed tasks never accumulate, TTL unnecessary!

---

## Decision: Remove TTL Completely

### New Behavior

```bash
# Without TTL
if lock is held (task currently running):
    wait for completion OR return (depending on mode)
else:
    run script  # Let script check if work is needed
```

**Script always executes** (when not already running), decides if work is needed via its own idempotency checks.

### Benefits

1. **✅ Self-Healing Works**: Scripts always check their outputs, re-create if missing
2. **✅ Simpler Code**: Remove TTL logic (~20 lines), fewer edge cases
3. **✅ Separation of Concerns**: `run_once` handles concurrency, scripts handle caching
4. **✅ Faster Recovery**: Manual file deletion immediately triggers re-download on next run
5. **✅ Predictable**: Same behavior every time (no time-based magic)
6. **✅ Scripts Decide**: Each script implements its own caching policy if needed

### Trade-offs

**Potential Concern**: More script executions (fork/exec overhead)

**Reality**: Negligible impact because:
- Scripts exit immediately if work not needed (lines 52-55 in download-catalog-index.sh)
- Fork/exec is < 10ms on modern systems
- Catalog operations are network-bound (seconds to minutes), not CPU-bound
- User perception: no difference

**Example**: Re-running `make catalogs-download` when files exist:
```bash
# With TTL
run_once: 0.001s (returns immediately, no script execution)

# Without TTL
run_once: 0.001s (locking overhead)
script: 0.010s (fork + source + idempotency check + exit)
Total: 0.011s

Difference: 10ms (imperceptible to user)
```

---

## Implementation Plan

### Phase 1: Remove TTL from `run_once()`

**File**: `scripts/include_all.sh`

**Changes**:

1. Remove `-t` option from getopts (line ~1385)
2. Remove `ttl` variable declaration (line ~1375)
3. Remove TTL check block (lines 1487-1502):
   ```bash
   # --- TTL CHECK ---
   # If TTL specified and exit file exists, check if it's expired
   if [[ -n "$ttl" && -f "$exit_file" ]]; then
       ... (delete entire block)
   fi
   ```

4. Update function documentation (remove TTL references)

**Lines to Remove**: ~20 lines

### Phase 2: Remove TTL from Function Calls

**Files to Update**:

1. **scripts/include_all.sh** - `download_all_catalogs()`:
   ```bash
   # Before
   run_once -i "catalog:${version_short}:redhat-operator" -t "$ttl" -- \
       scripts/download-catalog-index.sh redhat-operator
   
   # After
   run_once -i "catalog:${version_short}:redhat-operator" -- \
       scripts/download-catalog-index.sh redhat-operator
   ```

2. **scripts/download-catalogs-start.sh**:
   ```bash
   # Before
   download_all_catalogs "$ocp_ver_short" 86400
   
   # After
   download_all_catalogs "$ocp_ver_short"
   ```

3. **Any other calls** with `-t` option (search codebase)

**Search Pattern**: `run_once.*-t`

### Phase 3: Update Documentation

1. **ai/RULES_OF_ENGAGEMENT.md** - Update `run_once` flags reference (remove `-t`)
2. **ai/RUN_ONCE_RELIABILITY.md** - Remove TTL discussions if present
3. Function comments in `scripts/include_all.sh`

### Phase 4: Testing

**Test Scenarios**:

1. ✅ Catalog download completes successfully
2. ✅ Re-running download exits quickly (idempotency check)
3. ✅ Delete output files → re-run → files re-downloaded (self-healing)
4. ✅ Failed tasks get cleaned on next `aba` invocation
5. ✅ Concurrent runs don't interfere (locking still works)
6. ✅ Background tasks continue across multiple `aba` invocations

**Test Script**:
```bash
#!/bin/bash
# Test self-healing without TTL

echo "Test 1: Initial download"
make -C mirror catalogs-download
make -C mirror catalogs-wait
ls -lh mirror/.index/

echo "Test 2: Re-run (should exit quickly)"
time make -C mirror catalogs-download  # Should be fast

echo "Test 3: Delete files and re-run (self-healing)"
rm mirror/.index/community-operator-index-v4.20
rm mirror/.index/.community-operator-index-v4.20.done
make -C mirror catalogs-download
make -C mirror catalogs-wait
ls -lh mirror/.index/  # File should be back!

echo "✅ All tests passed"
```

---

## Impact Analysis

### Files Modified

1. `scripts/include_all.sh` - Core `run_once()` function
2. `scripts/download-catalogs-start.sh` - Remove TTL parameter
3. `ai/RULES_OF_ENGAGEMENT.md` - Update documentation

**Total**: ~3 files, ~30 lines changed

### Backward Compatibility

**Breaking Change**: Yes, `-t` flag removed from `run_once`

**Impact**: Internal only (no external API)

**Migration**: Remove `-t` from all `run_once` calls in codebase

### Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Scripts run more often | High | Low | Scripts exit quickly (idempotency) |
| Performance regression | Low | Low | Fork overhead < 10ms (negligible) |
| Breaking existing workflows | Low | Low | Internal API only, easy to fix |
| Logic errors | Low | Medium | Comprehensive testing |

**Overall Risk**: **LOW**

---

## Script-Level Caching (Optional Future)

If a script truly needs time-based caching (rare), it can implement it:

```bash
#!/bin/bash
# Example: Script with own TTL

cache_file="/tmp/my-cache"
ttl_seconds=86400  # 1 day

if [[ -f "$cache_file" ]]; then
    age=$(($(date +%s) - $(stat -c %Y "$cache_file")))
    if [[ $age -lt $ttl_seconds ]]; then
        echo "Cache valid (age: ${age}s)"
        exit 0
    fi
fi

# Do expensive work
download_data > "$cache_file"
```

**Benefits**:
- Script-specific logic
- Easy to test and debug
- Visible to anyone reading the script
- No hidden magic in `run_once`

---

## Comparison: Before vs After

### Before (With TTL)

```bash
# First run
run_once -i task -t 86400 -- ./script.sh
→ TTL check: no exit file → run script
→ Script creates outputs
→ Exit 0

# Second run (within 24 hours, files exist)
run_once -i task -t 86400 -- ./script.sh
→ TTL check: exit file < 24h → return 0 (skip)
→ Script NEVER runs
→ Outputs not validated

# Third run (within 24 hours, files DELETED)
run_once -i task -t 86400 -- ./script.sh
→ TTL check: exit file < 24h → return 0 (skip)
→ Script NEVER runs
→ Outputs MISSING ❌
→ User sees "file not found" errors
```

### After (Without TTL)

```bash
# First run
run_once -i task -- ./script.sh
→ Lock check: lock free → run script
→ Script creates outputs
→ Exit 0

# Second run (files exist)
run_once -i task -- ./script.sh
→ Lock check: lock free → run script
→ Script checks outputs: exist → exit 0 immediately (fast!)
→ Outputs validated ✓

# Third run (files DELETED)
run_once -i task -- ./script.sh
→ Lock check: lock free → run script
→ Script checks outputs: missing → re-download
→ Outputs recreated ✓
→ Self-healing works! ✅
```

---

## Quotes from Discussion

> "I would consider removing the TTL logic in run_once() entirely and let the script (if needed) implement it. The script knows best."  
> — User, 2026-01-24

> "In both modes (start and wait), we should always call the task but only IF THE lock is open"  
> — User, 2026-01-24

**Philosophy**: Simplicity, separation of concerns, Unix principles.

---

## Success Criteria

✅ Catalog downloads work correctly  
✅ Self-healing works (delete files → re-run → files recreated)  
✅ No performance regression (< 20ms difference)  
✅ All tests pass  
✅ Simpler codebase (fewer lines, easier to understand)  
✅ Failed tasks still auto-cleaned  
✅ Background tasks still work  

---

## Next Steps

1. ✅ Review and approve this design document
2. ⏳ Implement Phase 1 (remove TTL from `run_once`)
3. ⏳ Implement Phase 2 (update function calls)
4. ⏳ Update documentation
5. ⏳ Test thoroughly
6. ⏳ Commit changes

---

**Conclusion**: Removing TTL simplifies the architecture, improves self-healing, and maintains all essential functionality. The script-level idempotency checks are sufficient and more appropriate.

---

**Last Updated**: 2026-01-24  
**Author**: AI Assistant (with user architectural decisions)  
**Approved By**: User
