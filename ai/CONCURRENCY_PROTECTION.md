# Script Concurrency Protection

**Date**: January 2026  
**Issue**: Prevent multiple instances of aba operations from running simultaneously

## Current State

### What's Protected ✅

**`run_once()` already provides locking** for background tasks:
- Catalog downloads (one per catalog)
- Binary installations (oc-mirror, etc.)
- Background operations

**How it works**:
```bash
# Only one instance runs, others wait
run_once -w -i task:id -- command
```

Uses `flock` for mutual exclusion - rock solid.

### What's NOT Protected ❌

**Main aba commands can run concurrently**:
```bash
# Both will run simultaneously - CONFLICT!
aba -d mirror save    # Terminal 1
aba -d mirror save    # Terminal 2
```

**Dangerous scenarios**:
1. Multiple `aba -d mirror save` → oc-mirror conflicts, corrupted state
2. Multiple `aba -d mirror install` → registry installation conflicts
3. Multiple `aba bundle` → tar file write conflicts
4. Multiple `aba -d mirror sync` → oc-mirror conflicts

## Proposed Solutions

### Option 1: Global ABA Lock (Simplest) ✅

**Add single global lock for entire aba command**:

```bash
# In scripts/aba.sh, near the top (after sourcing include_all.sh)

ABA_LOCK_FILE="$HOME/.aba/aba.lock"
mkdir -p "$HOME/.aba"

# Try to acquire global lock
exec 200>"$ABA_LOCK_FILE"
if ! flock -n 200; then
    # Lock is held by another aba instance
    echo "Error: Another aba command is already running." >&2
    echo "If you're sure no other aba is running, remove: $ABA_LOCK_FILE" >&2
    exit 1
fi

# Lock automatically released when script exits (FD 200 closes)
```

**Benefits**:
- ✅ Simple - 5 lines of code
- ✅ Prevents ALL concurrent aba operations
- ✅ Automatic cleanup (lock released on exit)
- ✅ Works even with Ctrl-C (FD closes)

**Drawbacks**:
- ❌ Too restrictive - prevents `aba` in one terminal while another is running
- ❌ Can't run `aba help` while `aba save` is running

### Option 2: Per-Operation Locks (Better) ✅

**Lock only operations that conflict**:

```bash
# In scripts/aba.sh, add locking for specific operations

aba_lock_operation() {
    local operation="$1"
    local lock_file="$HOME/.aba/aba-${operation}.lock"
    
    mkdir -p "$HOME/.aba"
    exec 200>"$lock_file"
    
    if ! flock -n 200; then
        echo "Error: 'aba $operation' is already running in another terminal." >&2
        echo "" >&2
        echo "To see what's running:" >&2
        echo "  ps aux | grep 'aba.*$operation'" >&2
        echo "" >&2
        echo "If you're sure nothing is running, remove:" >&2
        echo "  rm -f $lock_file" >&2
        exit 1
    fi
    
    # Lock held via FD 200 until script exits
}

# Then in the command handling:
case "$command" in
    save|sync|load)
        aba_lock_operation "mirror-$command"
        # ... rest of command
        ;;
    bundle)
        aba_lock_operation "bundle"
        # ... rest of command
        ;;
    install|uninstall)
        aba_lock_operation "registry-$command"
        # ... rest of command
        ;;
esac
```

**Operations to lock**:
- `aba -d mirror save` → Lock: `aba-mirror-save.lock`
- `aba -d mirror sync` → Lock: `aba-mirror-sync.lock`
- `aba -d mirror load` → Lock: `aba-mirror-load.lock`
- `aba -d mirror install` → Lock: `aba-registry-install.lock`
- `aba bundle` → Lock: `aba-bundle.lock`

**Operations NOT locked** (safe to run concurrently):
- `aba help`
- `aba version`
- `aba -d mirror verify`
- `aba -c f` (config operations)

**Benefits**:
- ✅ Prevents conflicts where they matter
- ✅ Allows safe concurrent operations
- ✅ Clear error messages
- ✅ Automatic cleanup

**Drawbacks**:
- ⚠️ Need to identify which operations conflict
- ⚠️ Slightly more code

### Option 3: Warning Only (Lightest Touch)

**Just warn user, don't block**:

```bash
# Check if another aba is running
if pgrep -f "bash.*aba " | grep -v "$$" >/dev/null; then
    echo "Warning: Another aba command appears to be running." >&2
    echo "Press Ctrl-C to cancel, or Enter to continue anyway..." >&2
    read -r
fi
```

**Benefits**:
- ✅ Least intrusive
- ✅ User can override if they know what they're doing

**Drawbacks**:
- ❌ Doesn't actually prevent conflicts
- ❌ User might just hit Enter without thinking

## Recommendation

**Start with Option 2: Per-Operation Locks** ✅

**Why**:
1. Prevents real conflicts (multiple `save`, `sync`, etc.)
2. Still allows safe concurrent operations (`help`, `verify`, etc.)
3. Clear error messages help users understand what's happening
4. Automatic cleanup (no stale locks after Ctrl-C)

**Implementation**:
1. Add `aba_lock_operation()` helper to `scripts/include_all.sh`
2. Call it from `scripts/aba.sh` for conflicting operations
3. Test with: `aba -d mirror save & aba -d mirror save`

## Which Operations Need Locking?

### Critical (MUST lock):
- `aba -d mirror save` - oc-mirror disk write
- `aba -d mirror sync` - oc-mirror direct sync
- `aba -d mirror load` - oc-mirror disk read + registry write
- `aba -d mirror install` - registry installation
- `aba -d mirror uninstall` - registry removal
- `aba bundle` - tar file creation

### Safe (NO lock needed):
- `aba help`, `aba version` - read-only
- `aba -c f` - config editing (user's responsibility)
- `aba -d mirror verify` - read-only check
- `aba -d mirror imagesetconf` - config generation (mostly safe)

### Maybe (consider):
- `aba cluster` operations - long-running, but different namespace
- `aba make` operations - depends on what's being made

## Testing

```bash
# Test concurrent save (should block second)
aba -d mirror save &
sleep 1
aba -d mirror save  # Should fail with clear message

# Test mixed operations (should work)
aba -d mirror save &
sleep 1
aba help            # Should work fine
```

## Alternative: Use run_once for Everything?

**Could we use existing run_once() for main operations?**

```bash
# Instead of running directly:
aba -d mirror save

# Could become:
run_once -w -i mirror:save -- scripts/reg-save.sh

# Benefits: Reuse existing infrastructure
# Drawbacks: Changes command semantics (becomes idempotent)
```

**Probably not ideal** - users expect to be able to run `save` multiple times (e.g., after editing imageset config).

## Summary

**Recommended**: Implement Option 2 (Per-Operation Locks)

**Where to add**:
1. Helper function in `scripts/include_all.sh`
2. Lock checks in `scripts/aba.sh` for critical operations
3. Clear error messages with troubleshooting hints

**Next steps**:
1. Review which operations need locking
2. Implement `aba_lock_operation()` helper
3. Add locks to critical operations
4. Test concurrent execution scenarios

---

**Status**: Analysis complete, awaiting decision on implementation

