# Install Script Cleanup Strategy

**Date**: January 2026  
**Goal**: Make `./install` a safe "reset button" for troubleshooting

## Current Behavior

**Lines 124-125**:
```bash
mkdir -p ~/.aba
rm -rf ~/.aba/*  # Just to be sure!
```

**Problem**: This removes EVERYTHING in `~/.aba/`, which includes:
- `~/.aba/runner/*` - run_once state (good to clean)
- `~/.aba/ssh.conf` - SSH config (recreated on line 127-134, so OK)
- Any other state files users might have

**Issue**: Too aggressive, but mostly harmless since only ssh.conf is currently used.

## Proposed Improvements

### Option 1: Selective Cleanup (Recommended) ✅

**Philosophy**: Clean only problematic state, preserve expensive work.

```bash
mkdir -p ~/.aba

# Clean up runner state (stale locks, PIDs, exit codes)
if [ -d ~/.aba/runner ]; then
    echo "Cleaning up background task state..." >&2
    rm -rf ~/.aba/runner/*
fi

# Recreate ssh.conf (always overwrite for latest settings)
cat > ~/.aba/ssh.conf <<END
...
END
```

**Benefits**:
- ✅ Removes stale run_once state
- ✅ Preserves other files if added in future
- ✅ Clear about what's being cleaned
- ✅ Safe to run multiple times

### Option 2: Add --clean Flag

**Philosophy**: Normal install preserves state, `--clean` wipes everything.

```bash
# Check options
clean_state=0
while echo "$1" | grep -q "^-"
do
    [ "$1" = "-q" ] && quiet=1 && shift
    [ "$1" = "-v" ] && cur_ver=$2 && shift 2
    [ "$1" = "--clean" ] && clean_state=1 && shift
done

# Later...
mkdir -p ~/.aba

if [ "$clean_state" -eq 1 ]; then
    echo "Cleaning all ABA state (--clean specified)..." >&2
    rm -rf ~/.aba/*
else
    # Just clean runner state
    [ -d ~/.aba/runner ] && rm -rf ~/.aba/runner/*
fi

cat > ~/.aba/ssh.conf <<END
...
END
```

**Usage**:
```bash
./install              # Normal: Clean runner state only
./install --clean      # Full reset: Wipe everything
```

### Option 3: Keep Current Behavior

**Current is actually fine** since:
- `~/.aba/*` is recreated as needed
- Only `ssh.conf` exists there currently
- `runner/` directory is created on-demand by run_once
- No user data lives in `~/.aba/` yet

**Justification**: YAGNI (You Ain't Gonna Need It) - current behavior is sufficient.

## Recommended Approach

**Start with Option 3** (keep current) because:
1. Current behavior already cleans runner state
2. No user data in `~/.aba/` to preserve
3. Simple and works

**Future**: If we add persistent state to `~/.aba/`, implement Option 1 or 2.

## User Communication

Update documentation to reflect this behavior:

### README.md or TROUBLESHOOTING.md

```markdown
## Troubleshooting

### Issues with Stale Background Tasks

If you experience issues with stuck downloads or background tasks:

```bash
# Quick reset - removes all cached state
./install
```

This will clean up:
- Stale background task state (`~/.aba/runner/`)
- Lock files from interrupted runs
- Cached task results

Then try your command again:
```bash
aba -d mirror save
```

### Complete Clean Start

For a completely fresh environment:
```bash
cd ~/aba
./install
rm -rf mirror/.index/*        # Remove catalog indexes
rm -f cli/oc-mirror           # Remove downloaded binaries (optional)
make -C mirror clean          # Clean mirror state
```
```

## Implementation

**Recommendation**: Keep current behavior (Option 3) but **document it clearly**.

**Add to RULES_OF_ENGAGEMENT.md**:

```markdown
## Troubleshooting Pattern

**User Support**: If users report issues, first response is:

```bash
./install  # Cleans up stale state, reinstalls aba
```

The install script automatically:
- ✅ Cleans `~/.aba/` state (including runner/)
- ✅ Reinstalls aba to $PATH
- ✅ Updates RPM packages
- ✅ Recreates SSH config

Then user retries their command. This fixes 90% of "weird state" issues.
```

## Summary

✅ **Current `./install` behavior is good** - already cleans runner state  
✅ **Document this as the support pattern**  
✅ **No code changes needed** (unless we add persistent state later)  
✅ **User-friendly**: Single command to fix issues

---

**Status**: Analysis complete, recommend documenting current behavior  
**Action**: Update RULES_OF_ENGAGEMENT.md with troubleshooting pattern

