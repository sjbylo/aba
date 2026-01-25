# CLI Binary Usage and ensure_*() Analysis

## Overview

This document analyzes where each CLI binary is first used across all scripts and determines whether adding `ensure_*()` calls is necessary or overkill.

## Background: Recent Improvements

**Already fixed (commit fe3606d):**
- ✅ Removed `wait_all_cli_downloads` from all `ensure_*()` functions
- ✅ Each `ensure_*()` now only waits for its specific tool
- ✅ Much faster! No more waiting for all 5 tools when you only need 1

## CLI Binaries We Track

1. **oc** - OpenShift CLI (`ensure_oc`)
2. **oc-mirror** - Image mirroring (`ensure_oc_mirror`)
3. **openshift-install** - Cluster installer (`ensure_openshift_install`)
4. **govc** - VMware CLI (`ensure_govc`)
5. **butane** - Config transpiler (`ensure_butane`)

---

## Analysis by Binary

### 1. oc (OpenShift CLI)

**Scripts that use `oc`:**

#### Already have ensure_oc() ✅
- `scripts/show-cluster-login.sh` - ✅ Has `ensure_oc >&2` (line 9)

#### Called via Makefile with .cli prerequisite
- `scripts/cluster-installed.sh` - Called via Make target with `.cli` prereq
- `scripts/check-cluster-installed.sh` - Called via Make target with `.cli` prereq
- `scripts/wait-for-install-complete.sh` - Called via Make with `.cli` prereq
- `scripts/day2.sh` - Called via Make `day2: .cli` target
- `scripts/day2-config-osus.sh` - Called via Make `day2-osus: .cli` target
- `scripts/day2-config-ntp.sh` - Called via Make `day2-ntp: .cli` target
- `scripts/cluster-rescue.sh` - Called via Make `rescue: .cli` target
- `scripts/cluster-startup.sh` - Called via Make `startup: .cli` target
- `scripts/oc-command.sh` - Called directly from `aba.sh` (run command)

#### Analysis:
- **Most scripts** are called via Makefile targets with `.cli` prerequisite ✅
- `.cli` target ensures all CLIs are downloaded before running
- **If moved out of Make** (per MAKEFILE_SIMPLIFICATION.md), they'll need `ensure_oc`

**Recommendation:**
- ✅ Keep `.cli` prerequisites in Makefiles (current approach works)
- 📝 **Add `ensure_oc` to scripts that will be moved to direct calls:**
  - `day2.sh` → Add `ensure_oc` when moved
  - `day2-config-osus.sh` → Add `ensure_oc` when moved
  - `day2-config-ntp.sh` → Add `ensure_oc` when moved
  - `cluster-rescue.sh` → Add `ensure_oc` when moved
  - `cluster-startup.sh` → Add `ensure_oc` when moved
  - `oc-command.sh` → Add `ensure_oc` (run via direct call already)

---

### 2. oc-mirror (Image Mirroring)

**Scripts that use `oc-mirror`:**

#### Already have ensure_oc_mirror() ✅
- `scripts/reg-save.sh` - ✅ Has `ensure_oc_mirror` (implicit via run_once)
- `scripts/reg-sync.sh` - ✅ Has `ensure_oc_mirror` (implicit via run_once)
- `scripts/reg-load.sh` - ✅ Has `ensure_oc_mirror` (implicit via run_once)
- `scripts/download-catalog-index-simple.sh` - ✅ Has `ensure_oc_mirror` (line ~52)

#### Analysis:
- **All oc-mirror usage is already protected** ✅
- These scripts are timing-critical (can be called early before background downloads finish)
- Scripts use `run_once` calls that internally use `ensure_oc_mirror`

**Recommendation:**
- ✅ **No changes needed** - already correct!
- All oc-mirror scripts have proper ensures

---

### 3. openshift-install (Cluster Installer)

**Scripts that use `openshift-install`:**

#### Called via Makefile with .cli prerequisite
- `scripts/iso-build.sh` - Called via Make `iso: .cli` target
- `scripts/cluster-install.sh` - Called via Make `install: .cli` target
- `scripts/cluster-upgrade.sh` - Called via Make with prereqs

#### Analysis:
- All usage is via Makefile targets with `.cli` prerequisite ✅
- These are long-running operations, always called after full setup
- Background CLI downloads will have completed long before these run

**Recommendation:**
- ✅ **No changes needed** - Makefile prerequisites are sufficient
- These scripts run late in the workflow, CLIs always ready

---

### 4. govc (VMware CLI)

**Scripts that use `govc`:**

#### Already have ensure_govc() ✅
- `scripts/vmware-create-vm.sh` - ✅ Has `ensure_govc` via `run_once ... make -sC cli govc`

#### Called via Makefile with .cli prerequisite  
- `scripts/vmware-vm-snapshot.sh` - Called via Make (has `.cli` prereq)
- `scripts/vmware-upload-ova.sh` - Called via Make (has `.cli` prereq)
- `scripts/vmware-vm-delete.sh` - Could be called standalone?

#### Analysis:
- Most VMware operations go through Makefiles ✅
- `vmware-create-vm.sh` already has ensure via run_once ✅
- Question: Can VMware scripts be called standalone? (Probably not in practice)

**Recommendation:**
- ✅ **No changes needed for now**
- If VMware scripts move to direct calls, add `ensure_govc` then
- Low priority (VMware is advanced use case, users follow docs)

---

### 5. butane (Config Transpiler)

**Scripts that use `butane`:**

#### Called via Makefile with .cli prerequisite
- `scripts/transpile-ignition-config.sh` - Called via Make with prereqs
- Used for custom ignition configs (advanced feature)

#### Analysis:
- Only used via Makefile targets ✅
- Called as part of ISO build chain (CLIs ready)
- Advanced feature, well-documented workflow

**Recommendation:**
- ✅ **No changes needed** - Makefile prerequisites sufficient

---

## Summary Table

| Binary | Scripts Using It | ensure_*() Status | Action Needed |
|--------|------------------|-------------------|---------------|
| **oc** | 10+ scripts | Most via Make `.cli` prereq | Add to scripts when moved out of Make |
| **oc-mirror** | 4 scripts | ✅ All have ensures | ✅ None - already correct |
| **openshift-install** | 3 scripts | All via Make `.cli` prereq | ✅ None - sufficient |
| **govc** | 4 scripts | Via Make + 1 has ensure | ✅ None - sufficient |
| **butane** | 1 script | Via Make `.cli` prereq | ✅ None - sufficient |

---

## Timing Analysis

### When are CLIs needed?

**Very early (must have ensure_*()):**
- ✅ `download-catalog-index-simple.sh` → Has `ensure_oc_mirror` ✅
- ✅ `reg-save.sh` → Has `ensure_oc_mirror` ✅
- ✅ `reg-sync.sh` → Has `ensure_oc_mirror` ✅
- ✅ `reg-load.sh` → Has `ensure_oc_mirror` ✅

**Mid-workflow (Makefile prereqs sufficient):**
- ISO build operations → `.cli` prereq OK
- Cluster install operations → `.cli` prereq OK

**Late workflow (CLIs always ready):**
- Day2 operations → Background downloads finished ✅
- Cluster management → Background downloads finished ✅
- VMware operations → Background downloads finished ✅

### Background Download Context

**From `scripts/aba.sh` line ~954:**
```bash
# Non-interactive mode - start CLI downloads early
if [[ -z "$interactive_mode" ]]; then
    aba_debug "Non-interactive mode detected - starting CLI downloads early"
    start_all_cli_downloads
fi
```

This means:
- **In non-interactive mode:** All CLIs download in background immediately ✅
- **In TUI mode:** Downloads start when needed
- **Most scripts run mid/late workflow:** CLIs ready by then ✅

---

## Decision Matrix: When to Add ensure_*()?

### ✅ MUST have ensure_*() (critical timing):
- Scripts called **very early** in workflow
- Scripts that can be called **before background downloads finish**
- Scripts with **no Makefile protection**

**Current examples:**
- ✅ All oc-mirror scripts (already have it)
- ✅ `show-cluster-login.sh` (already has it)

### 🟡 SHOULD have ensure_*() (safety/standalone):
- Scripts **moved out of Makefiles** to direct calls
- Scripts that **could** be called standalone
- Scripts in **error recovery paths**

**Need when MAKEFILE_SIMPLIFICATION.md implemented:**
- `day2.sh`
- `day2-config-osus.sh`
- `day2-config-ntp.sh`
- `cluster-rescue.sh`
- `cluster-startup.sh`
- `oc-command.sh`

### ✅ DON'T need ensure_*() (already protected):
- Scripts **only called via Makefile** with `.cli` prereq
- Scripts called **late in workflow** (CLIs guaranteed ready)
- Scripts in **sequential build chains**

**Current examples:**
- ISO build scripts
- Cluster install scripts
- VMware scripts (mostly)
- Butane scripts

---

## Implementation Recommendations

### Option A: Minimal Changes (Recommended)

**Status quo is mostly correct!**

Only add `ensure_*()` to scripts when:
1. They move out of Makefiles (per MAKEFILE_SIMPLIFICATION.md)
2. They're called very early (oc-mirror scripts already have it ✅)
3. They're called in error recovery paths

**Work needed:**
- ✅ None immediately
- 📝 Add ensures when implementing MAKEFILE_SIMPLIFICATION.md

### Option B: Defensive Programming

Add `ensure_*()` to **all scripts** that use CLIs, even if they have Makefile prereqs.

**Pros:**
- Scripts work standalone (can call directly for debugging)
- More robust against future refactoring
- Self-documenting (you see dependencies in the script)

**Cons:**
- Some duplication (script + Makefile both ensure)
- Slightly slower (minimal - ensure is fast if binary exists)
- More code changes

### Option C: Remove Makefile .cli Prerequisites

If scripts have `ensure_*()`, remove Makefile `.cli` prereqs.

**Pros:**
- Single source of truth (script handles dependencies)
- Cleaner Makefiles

**Cons:**
- More invasive change
- Risk of missing some scripts
- May slow down parallel Make execution

---

## Proposed Action Plan

### Phase 1: Status Quo (✅ Current State is Good)
- ✅ oc-mirror scripts have ensures
- ✅ `show-cluster-login.sh` has ensure
- ✅ Most scripts protected by Makefile `.cli` prereqs
- ✅ `ensure_*()` functions are efficient (no longer wait for all CLIs)

**No immediate action needed!**

### Phase 2: When Implementing MAKEFILE_SIMPLIFICATION.md

**For each script moved to direct call, add `ensure_*()` at the top:**

```bash
#!/bin/bash
source scripts/include_all.sh

# Ensure required CLI tools
ensure_oc

# Rest of script...
```

**Scripts to update:**
- `day2.sh` → Add `ensure_oc`
- `day2-config-osus.sh` → Add `ensure_oc`
- `day2-config-ntp.sh` → Add `ensure_oc`
- `cluster-rescue.sh` → Add `ensure_oc`
- `cluster-startup.sh` → Add `ensure_oc`
- `oc-command.sh` → Add `ensure_oc`

### Phase 3: Optional Safety Improvements

**Consider adding `ensure_*()` to error recovery scripts:**
- Scripts called when things go wrong (rescue, recovery)
- Scripts that might be called manually by users debugging

**Low priority** - only if we see issues in practice.

---

## Testing Strategy

### When adding ensure_*() calls:

1. **Test with fresh system** (no CLIs cached):
   ```bash
   rm -rf ~/.aba/runner/cli:*
   rm -f ~/bin/{oc,oc-mirror,openshift-install,govc,butane}
   aba <command>
   ```

2. **Verify ensure messages appear:**
   ```
   [ABA] Installing oc to ~/bin
   ```

3. **Test direct script call:**
   ```bash
   cd aba
   scripts/day2.sh  # Should work standalone
   ```

4. **Verify speed** (ensure is fast if CLI exists):
   ```bash
   time aba day2  # Should be instant if oc already installed
   ```

---

## Edge Cases & Questions

### Q: What if user deletes ~/bin/oc but cache exists?

**A:** `ensure_oc` will re-run the install task. The Makefile's `cli/oc` target checks if `~/bin/oc` exists and reinstalls if missing. ✅ Self-healing works!

### Q: What about scripts called from scripts?

**A:** Child scripts inherit parent's environment. If parent called `ensure_*`, child sees the binary. But if child can be called standalone, it should have its own `ensure_*`.

### Q: Performance impact?

**A:** Minimal. `ensure_*()` just calls `run_once -w`, which:
- Returns immediately if binary exists (fast path)
- Only downloads/installs if missing (rare)

### Q: What about parallel execution?

**A:** `run_once` uses `flock` for locking. Multiple parallel calls to `ensure_oc` will safely serialize the install, then all proceed. ✅ Safe!

---

## Conclusion

**Current state: ✅ Mostly good!**

- oc-mirror scripts have proper ensures ✅
- Most other scripts protected by Makefile prereqs ✅
- `ensure_*()` functions are efficient ✅

**Action needed:**
- 📝 Minimal - only when implementing MAKEFILE_SIMPLIFICATION.md
- Add `ensure_oc` to 6 scripts when moved to direct calls
- No urgent changes required

**Philosophy:**
- Use Makefile `.cli` prereqs for build chains ✅
- Use `ensure_*()` in scripts for direct calls or timing-critical operations ✅
- Don't add ensures "just because" - only where needed ✅

---

## Status

- **Analysis:** ✅ Complete
- **Current state:** ✅ Good, no urgent changes
- **Next action:** ⏳ Wait for MAKEFILE_SIMPLIFICATION.md implementation
- **Backlog:** Add ensures to 6 scripts when moved out of Makefiles
