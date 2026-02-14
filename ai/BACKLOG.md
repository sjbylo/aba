# ABA Technical Backlog

This file tracks architectural improvements and technical debt that should be addressed in future releases.

---

## High Priority

### 1. Systematic Script Directory Management Cleanup

**Status:** Backlog  
**Priority:** High  
**Estimated Effort:** Large (16+ scripts to review/update)  
**Created:** 2026-01-23

**Problem:**
Currently, scripts have inconsistent directory management practices:
- 16+ scripts do `cd "$(dirname "$0")/.."` to change to ABA_ROOT or mirror/
- Some scripts trust Makefile's CWD (correct per architecture)
- Some scripts force their own execution context (violates architecture)
- This inconsistency led to the need for CWD restoration in `run_once` self-healing

**Current Workaround:**
`run_once` saves and restores CWD during self-healing validation to handle mixed architecture.

**Architecture Principle (from RULES_OF_ENGAGEMENT.md):**
> **Key Principle**: Scripts don't "know" their execution context from where they're stored. The **Makefile** that calls them sets their working directory (CWD).

**Scripts That Need Review:**
```bash
# Scripts that cd to mirror/:
- scripts/reg-load.sh
- scripts/reg-save.sh
- scripts/reg-sync.sh
- scripts/download-catalogs-wait.sh
- scripts/download-catalogs-start.sh
- scripts/reg-create-imageset-config-sync.sh
- scripts/reg-create-imageset-config-save.sh
- scripts/check-version-mismatch.sh

# Scripts that cd to ABA_ROOT:
- scripts/ensure-cli.sh
- scripts/run-once.sh
- scripts/make-bundle.sh
- scripts/install-rpms.sh
- scripts/download-and-wait-catalogs.sh
- scripts/cli-install-all.sh
- scripts/cli-download-all.sh
- scripts/cleanup-runner.sh
- scripts/download-catalog-index.sh
```

**Recommended Approach:**

1. **Audit Phase** (1-2 hours)
   - For each script, determine if `cd` is necessary or violates architecture
   - Check if script can trust Makefile's CWD + symlinks
   - Document dependencies and callers

2. **Decision Criteria**
   - **Remove `cd`** if:
     - Script is called from Makefile (Makefile sets CWD)
     - Symlinks provide access to needed resources
     - Script doesn't need specific execution context
   - **Keep `cd`** if:
     - Script is called directly by users (e.g., `aba.sh`)
     - Script is a top-level entry point
     - No Makefile to set execution context

3. **Implementation** (4-6 hours)
   - Update scripts systematically
   - Test each change individually
   - Update callers if needed
   - Run full test suite after each group

4. **Validation**
   - All E2E tests pass
   - Mirror operations work (sync, save, load)
   - Bundle creation works
   - TUI works correctly

**Benefits:**
- ✅ Cleaner, more maintainable code
- ✅ Consistent with architecture principles
- ✅ Potentially remove CWD restoration from `run_once`
- ✅ Easier to debug (predictable execution context)
- ✅ Better preparation for `/opt/aba` migration

**Risks:**
- Breaking existing workflows if not careful
- Complex testing matrix (16+ scripts × multiple use cases)
- May uncover other hidden assumptions

**Dependencies:**
- None (can be done incrementally)

**Notes:**
- Current CWD restoration in `run_once` should **remain** until this cleanup is complete
- Can be done incrementally, one script or group at a time
- Consider documenting which scripts MUST cd (entry points) in RULES_OF_ENGAGEMENT.md

---

## Medium Priority

### 2. E2E Clone-Check: Parallelize VM Cloning and Configuration

**Status:** Backlog  
**Priority:** Medium  
**Estimated Effort:** Medium  
**Created:** 2026-02-12

**Current State:**
`suite-clone-check.sh` runs all steps sequentially (~11 minutes). Each `_vm_*` operation on con1 completes before the same operation starts on dis1.

**Proposed Optimization -- Parallel Operations:**

Steps that CAN be parallelized (independent per VM):
- SSH wait after power-on (both VMs boot simultaneously)
- SSH key setup on both VMs
- NTP on both (after con1 firewall is up)
- Cleanup (caches, podman, home) on both
- Config (vmware.conf, test user) on both

Steps that MUST stay sequential:
- Cloning: both share the same template; `clone_with_macs` reverts the template snapshot before each clone. Fix: revert once, then clone twice.
- con1 network + firewall + dnsmasq BEFORE dis1 network: dis1's default route goes through con1's VLAN masquerade.

**Estimated time saving:** ~11 min down to ~7-8 min.

### 3. E2E VM Reuse: Snapshot-Based Fast Restart

**Status:** Backlog  
**Priority:** Medium  
**Estimated Effort:** Medium  
**Created:** 2026-02-12

**Problem:**
Every clone-check run destroys and re-clones VMs from template, then reconfigures from scratch. This is the biggest time cost (~10 min) and is wasteful when the VMs are already configured correctly.

**Proposed Solution -- Three-tier reuse:**

1. **Snapshot reuse (fastest, ~30s):** After clone-check fully configures VMs, take a govc snapshot `e2e-configured`. On subsequent runs, if VMs exist with that snapshot, revert to it and power on. Guarantees clean, known-good state.

2. **Power-on + light cleanup (fast, ~60s):** Leave VMs powered off after tests. Next run powers on and runs a refresh (reset aba state, clean caches). Network/firewall/dnsmasq survive reboots. Slightly less deterministic than snapshots.

3. **Full re-clone (current, ~11 min):** Destroy VMs and clone fresh from template. Used with `--fresh` flag or when VMs don't exist.

**Recommended approach:** Hybrid -- snapshots for the clone-check / infra setup, light cleanup for the actual test suites that run on already-configured VMs. `--fresh` flag forces full re-clone.

**Implementation sketch:**
```bash
# In suite-clone-check.sh or a new pool-reuse.sh:
if vm_exists "$CON_NAME" && vm_has_snapshot "$CON_NAME" "e2e-configured"; then
    govc snapshot.revert -vm "$CON_NAME" e2e-configured
    govc vm.power -on "$CON_NAME"
    # ... same for DIS_NAME
else
    # full clone + configure pipeline
fi
# After full configure:
govc snapshot.create -vm "$CON_NAME" e2e-configured
govc snapshot.create -vm "$DIS_NAME" e2e-configured
```

## Low Priority

### 4. Validate starting_ip Is Within machine_network CIDR

**Status:** Backlog  
**Priority:** Low  
**Estimated Effort:** Small  
**Created:** 2026-02-14

**Problem:**
ABA does not check whether `starting_ip` (from cluster config) falls within the `machine_network` CIDR. If a user sets an IP outside the CIDR, the cluster install will fail late with a cryptic error rather than failing early with a clear message.

**Proposed Solution:**
Add an early validation (e.g., in `verify-aba-conf` or cluster config normalization) that parses the CIDR and checks the starting IP is within it. Pure bash approach: convert IP and network to integers, apply the mask, and compare. Alternatively, use `ipcalc` or Python one-liner if available.

**Where:**
- `scripts/include_all.sh` (in `verify-aba-conf` or a new `verify-cluster-conf`)
- Potentially also in the TUI when the user enters `starting_ip`

**Benefits:**
- Fail early with a clear error message
- Prevent wasted time on doomed installs

---

## Completed

*(Move completed items here with completion date)*
