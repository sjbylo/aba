# ABA Technical Backlog

This file tracks architectural improvements and technical debt that should be addressed in future releases.

---

## Medium Priority

### 1. E2E Clone-Check: Parallelize VM Cloning and Configuration

**Status:** Backlog  
**Priority:** Medium  
**Estimated Effort:** Medium  
**Created:** 2026-02-12

**Current State:**
`suite-clone-and-check.sh` runs all steps sequentially (~11 minutes). Each `_vm_*` operation on con1 completes before the same operation starts on dis1.

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

### 2. E2E VM Reuse: Snapshot-Based Fast Restart

**Status:** Backlog  
**Priority:** Medium  
**Estimated Effort:** Medium  
**Created:** 2026-02-12

**Problem:**
Every clone-and-check run destroys and re-clones VMs from template, then reconfigures from scratch. This is the biggest time cost (~10 min) and is wasteful when the VMs are already configured correctly.

**Proposed Solution -- Three-tier reuse:**

1. **Snapshot reuse (fastest, ~30s):** After clone-and-check fully configures VMs, take a govc snapshot `e2e-configured`. On subsequent runs, if VMs exist with that snapshot, revert to it and power on. Guarantees clean, known-good state.

2. **Power-on + light cleanup (fast, ~60s):** Leave VMs powered off after tests. Next run powers on and runs a refresh (reset aba state, clean caches). Network/firewall/dnsmasq survive reboots. Slightly less deterministic than snapshots.

3. **Full re-clone (current, ~11 min):** Destroy VMs and clone fresh from template. Used with `--fresh` flag or when VMs don't exist.

**Recommended approach:** Hybrid -- snapshots for the clone-and-check / infra setup, light cleanup for the actual test suites that run on already-configured VMs. `--fresh` flag forces full re-clone.

**Implementation sketch:**
```bash
# In suite-clone-and-check.sh or a new pool-reuse.sh:
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

### 3. Evaluate Selective `set -euo pipefail` Adoption

**Status:** Backlog  
**Priority:** Medium  
**Estimated Effort:** Very Large  
**Created:** 2026-02-18

**Problem:**
ABA core scripts do not use strict bash mode (`set -euo pipefail`). This means unhandled errors, unset variables, and broken pipelines can silently produce wrong results. However, enabling it globally is high-risk for existing code.

**Assessment:**
- `set -e` (errexit): HIGH RISK. Hundreds of patterns would break: `grep -q` returning 1 on no match, `(( counter++ ))` returning 1 when counter is 0, `diff` returning 1 on differences, etc. Many bash experts advise against global `-e`.
- `set -u` (nounset): MODERATE RISK. ABA uses many optional config variables that may be unset. Every `$var` reference would need `${var:-}` or `${var:-default}`.
- `set -o pipefail`: LOW RISK. Safest option, but patterns like `grep | head` would need review.

**Recommendation -- Incremental approach (do NOT enable globally):**
1. Use `set -euo pipefail` in all NEW scripts (already done for `setup-pool-registry.sh`)
2. Add `set -u` to core scripts incrementally, fixing unset variable references
3. Add `set -o pipefail` to core scripts incrementally
4. Add explicit error handling (`|| exit 1`, `|| return 1`) at critical points instead of relying on `-e`
5. Run ShellCheck on all scripts for static analysis (catches real bugs without `-e` foot-guns)

**Do NOT:**
- Enable `set -e` globally in `include_all.sh`
- Bulk-convert existing scripts without individual testing

**References:**
- http://mywiki.wooledge.org/BashFAQ/105 (why `set -e` is unreliable)
- The `(( running++ ))` bug in `download_all_catalogs()` was caused by `set -e` + post-increment returning 0

---

## Low Priority

### 4. Improve vmw-create.sh Output Formatting

**Status:** Backlog  
**Priority:** Low  
**Estimated Effort:** Small  
**Created:** 2026-02-26

**Problem:**
The VM creation output from `vmw-create.sh` is a dense wall of text with all parameters crammed onto one long line:
```
[ABA] Create VM: [ABA] sno-sno: [8C/20G] [Datastore4-2] [VMNET-DPG] [00:50:56:09:c9:01] [Datastore4-2:images/agent-sno.iso] [/Datacenter/vm/abatesting/sno]
```

**Proposed Solution:**
Format the VM creation output to be more readable, e.g.:
```
[ABA] Creating VM: sno-sno
        CPU/Mem:    8C / 20G
        Datastore:  Datastore4-2
        Network:    VMNET-DPG
        MAC:        00:50:56:09:c9:01
        ISO:        Datastore4-2:images/agent-sno.iso
        Folder:     /Datacenter/vm/abatesting/sno
```

**Where:**
- `scripts/vmw-create.sh`, the `create_node()` function (around line 91-92)

**Benefits:**
- Easier to read and verify at a glance
- Each parameter on its own line aids troubleshooting

---

---

## Completed

### Systematic Script Directory Management Cleanup
**Completed:** 2026-02-19  
Cleaned up inconsistent `cd` patterns across 16+ scripts. Scripts now consistently trust Makefile CWD + symlinks per architecture principles.

### Validate starting_ip Is Within machine_network CIDR
**Completed:** 2026-02-18 (commit d190310)  
Added `ip_to_int`, `int_to_ip`, `ip_in_cidr` helpers to `scripts/include_all.sh`.  
`verify-cluster-conf()` now checks: starting_ip within CIDR, all nodes fit, VIPs within CIDR (non-SNO).
