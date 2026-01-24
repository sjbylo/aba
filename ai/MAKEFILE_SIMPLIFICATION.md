# Makefile Simplification: Move No-Dependency Commands to Direct Calls

## Philosophy

**Make is designed for:**
- ✅ Building artifacts (ISOs, configs, bundles)
- ✅ Managing dependencies (A depends on B depends on C)
- ✅ Incremental builds (only rebuild what changed)
- ✅ Parallel execution of independent tasks

**Make is overkill for:**
- ❌ Simple script wrappers with zero dependencies
- ❌ Pure operational commands (day2, login, etc.)
- ❌ Commands that just execute a single script

## Current Pattern (Already Implemented)

In `scripts/aba.sh`, three commands have been moved out of Make:

```bash
if [ "$cur_target" ]; then
    aba_debug cur_target=$cur_target
    case $cur_target in
        ssh)
            trap - ERR
            $ABA_ROOT/scripts/ssh-rendezvous.sh "$cmd"
            exit
            ;;
        run)
            trap - ERR
            $ABA_ROOT/scripts/oc-command.sh "$cmd"
            exit
            ;;
        bundle)
            trap - ERR
            aba_debug Running: $ABA_ROOT/scripts/make-bundle.sh -o "$opt_out" $opt_force $opt_light
            eval $ABA_ROOT/scripts/make-bundle.sh $opt_out $opt_force $opt_light
            exit
            ;;
    esac
fi
```

**Benefits observed:**
- Cleaner code flow
- Faster execution (no Make overhead)
- Easier debugging
- More obvious what's happening

---

## Commands to Move OUT of Makefiles

### High Priority (No Real Dependencies)

**Day2 Operations:**
- `day2` → Call `scripts/day2.sh` directly
- `day2-osus` → Call `scripts/day2-config-osus.sh` directly
- `day2-ntp` → Call `scripts/day2-config-ntp.sh` directly

**Cluster Operations:**
- `login` → Already direct via `show-cluster-login.sh` ✅
- `shell` → Already direct ✅
- `startup` → Call `scripts/cluster-startup.sh` directly
- `rescue` → Call `scripts/cluster-rescue.sh` directly

**Informational:**
- `info` → If in Make, move to direct call
- `help` → If in Make, move to direct call
- `version` → If in Make, move to direct call

### Why These Should Move:

These commands:
1. Have **zero or trivial dependencies** (just need `oc` binary)
2. Are **operational** (not building artifacts)
3. Run **once** (no incremental build benefit)
4. Are **simple wrappers** around a single script

---

## Commands to KEEP in Makefiles

### Complex Build Chains (Real Dependencies)

**Installation & Cluster Creation:**
- `install` - Complex dependency chain (configs → ISO → install → monitor)
- `cluster` - Creates cluster directory, generates configs, has prerequisites
- `iso` - Builds ISO with dependencies (agentconf, rendezvous, configs)
- `agentconf` - Generates agent-config.yaml with prerequisites

**Mirror Operations:**
- `save` - Builds imageset config, downloads catalogs, runs oc-mirror
- `sync` - Same as save, plus registry checks
- `load` - Depends on save artifacts, registry access
- `catalogs-download`, `catalogs-wait` - Background tasks with file dependencies

**VMware Operations:**
- `vmw` - Depends on vmware.conf generation, govc availability
- VM lifecycle commands if they have prerequisites

### Why These Should Stay:

These commands:
1. Have **real dependency chains**
2. Build **artifacts** (ISOs, configs, YAMLs)
3. Benefit from **incremental builds** (Make's .PHONY and file timestamps)
4. Use **Make's parallel execution**
5. Have **complex prerequisite management**

---

## Handling CLI Tool Dependencies

### Problem:
When commands move out of Makefiles, they lose automatic `.cli` prerequisites.

### Solution 1: Add ensure_* to Scripts

**For scripts called directly**, add `ensure_*` at the top:

```bash
#!/bin/bash
source scripts/include_all.sh

# Ensure required CLIs are available
ensure_oc  # Only waits for oc, not all CLIs

# Rest of script...
```

**Scripts that need this:**
- `day2.sh` → Add `ensure_oc`
- `day2-config-osus.sh` → Add `ensure_oc`
- `day2-config-ntp.sh` → Add `ensure_oc`
- `cluster-rescue.sh` → Add `ensure_oc`
- `cluster-startup.sh` → Add `ensure_oc`
- VMware scripts → Add `ensure_govc` (if called standalone)

### Solution 2: Keep Makefile Prerequisites (Current Approach)

For scripts still called via Make, keep `.cli` prerequisites:

```makefile
day2: .cli
	$(SCRIPTS)/day2.sh

day2-osus: .cli  
	$(SCRIPTS)/day2-config-osus.sh
```

### Solution 3: Hybrid (Recommended)

- **In Makefiles:** Keep `.cli` prerequisites for commands that stay in Make
- **In Scripts:** Add `ensure_*` for commands moved to direct calls
- **Result:** Scripts work both ways (direct call or via Make)

---

## Timing Considerations

### Current Reality:

1. **`aba.sh` line 954** starts ALL CLI downloads in background at startup
2. **Most operations** happen AFTER startup, so CLIs are already available
3. **`ensure_*` functions** are fast if binary already exists (just returns)

### Scripts with Critical Timing:

**Must have ensure_* (can't rely on background download):**
- `reg-save.sh` → `ensure_oc_mirror` ✅ (already has it)
- `reg-sync.sh` → `ensure_oc_mirror` ✅ (already has it)
- `reg-load.sh` → `ensure_oc_mirror` ✅ (already has it)
- `download-catalog-index-simple.sh` → `ensure_oc_mirror` ✅ (already has it)

**Can rely on background download (but ensure_* is good safety):**
- `day2.sh` → Background downloads usually complete by cluster install
- VMware scripts → Usually run after cluster creation

---

## Implementation Plan

### Phase 1: Documentation
- ✅ Document philosophy and approach (this file)
- Review with team
- Identify any edge cases

### Phase 2: Move Commands (Day 2 Operations)

**Update `scripts/aba.sh`:**
```bash
case $cur_target in
    # ... existing ssh, run, bundle ...
    
    day2)
        trap - ERR
        $ABA_ROOT/scripts/day2.sh
        exit
        ;;
    day2-osus)
        trap - ERR
        $ABA_ROOT/scripts/day2-config-osus.sh
        exit
        ;;
    day2-ntp)
        trap - ERR
        $ABA_ROOT/scripts/day2-config-ntp.sh
        exit
        ;;
    startup)
        trap - ERR
        $ABA_ROOT/scripts/cluster-startup.sh
        exit
        ;;
    rescue)
        trap - ERR
        $ABA_ROOT/scripts/cluster-rescue.sh
        exit
        ;;
esac
```

**Update scripts (add ensure_oc at top):**
```bash
# scripts/day2.sh
#!/bin/bash -e
source scripts/include_all.sh
ensure_oc  # ← Add this line
# ... rest of script
```

**Remove from Makefiles:**
- Remove `day2`, `day2-osus`, `day2-ntp` targets from cluster Makefile
- Keep in Makefile help text or document elsewhere

### Phase 3: Testing

Test each moved command:
- Direct call: `aba day2`
- With fresh install (no CLIs cached)
- With existing CLIs
- Verify `ensure_oc` messages appear correctly

### Phase 4: Documentation Updates

Update:
- README.md with new command structure
- Any developer docs about when to use Make vs direct calls
- Help text to reflect architectural changes

---

## Decision Tree: Make vs Direct Call

```
Does the command build an artifact? (ISO, config, bundle)
├─ YES → Keep in Makefile
└─ NO
   └─ Does it have complex dependencies? (A needs B needs C)
      ├─ YES → Keep in Makefile
      └─ NO
         └─ Does it benefit from Make's incremental build?
            ├─ YES → Keep in Makefile
            └─ NO → **Move to direct call in aba.sh**
```

---

## Benefits Summary

### Before (Everything in Make):
- Make overhead for simple commands
- Harder to understand code flow
- Makefile complexity for no benefit
- Debugging requires understanding Make

### After (Direct calls for no-dep commands):
- ✅ Faster execution
- ✅ Clearer code flow
- ✅ Simpler Makefiles (only for builds)
- ✅ Easier debugging
- ✅ Scripts are self-documenting
- ✅ Each script manages its own deps

---

## Related Changes

### Wait for CLI Downloads

**Current approach:** `wait_all_cli_downloads()` - waits for ALL tools

**New approach:** Individual `ensure_*()` - only waits for needed tool
- `ensure_oc` - Only waits for oc
- `ensure_govc` - Only waits for govc
- Much faster! ✅

**Status:** Already implemented ✅ (see commit fe3606d)

---

## Open Questions

1. **Should we keep day2 commands in Makefile also?** (for backward compat)
   - Pro: Users can still run `make day2`
   - Con: Duplication, which one is "real"?
   - Decision: TBD

2. **What about cluster lifecycle commands?** (startup, stop, destroy)
   - Are they operational (move out) or build-related (keep in)?
   - Decision: TBD

3. **Should all scripts have ensure_* for safety?** (even if not moved)
   - Pro: Scripts work standalone
   - Con: Possible overkill, adds noise
   - Decision: Add only where timing-critical or moved out of Make

---

## Status

- **Phase 1:** ✅ Documentation complete
- **Phase 2:** ⏳ Awaiting decision to proceed
- **Phase 3:** ⏳ Not started
- **Phase 4:** ⏳ Not started

---

## References

- Commit fe3606d: Removed `wait_all_cli_downloads()` from ensure_* functions
- `scripts/aba.sh` lines 780-795: Existing pattern for ssh/run/bundle
- `scripts/include_all.sh` lines 2064-2092: ensure_* function definitions
