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

### 5. Persistent Registry State in `~/.aba/registry/`

**Status:** Backlog  
**Priority:** Medium  
**Estimated Effort:** Large  
**Created:** 2026-02-21  
**Design Doc:** `ai/DESIGN-docker-registry-first-class.md` section 9

**Problem:**
Registry install-time state (cert, pull-secret params, uninstall parameters) lives in `mirror/` which gets wiped by `aba reset -f` or `make clean`. After a reset, `aba -d mirror uninstall` fails because the Makefile can't find `aba.conf`:

```
Feb 21 06:32:21      >> cd /home/steve/aba && aba -d mirror uninstall
Makefile:116: *** "Value 'ocp_version' not set in aba.conf! Run aba in the root of Aba's repository or read the README.md file on how to get started.".  Stop.
```

**Proposed Solution:**
Move persistent registry state to `~/.aba/registry/state.sh` and `~/.aba/registry/rootCA.pem`. Uninstall reads from this persistent state instead of depending on workspace files. Full design in `ai/DESIGN-docker-registry-first-class.md`.

### 6. `aba mirror uninstall` Must Fully Clean Up Quay

**Status:** Backlog  
**Priority:** Medium  
**Estimated Effort:** Medium  
**Created:** 2026-02-21

**Problem:**
`aba -d mirror uninstall` does not fully tear down Quay. Rootless containers started with `--cgroups=no-conmon` are managed by systemd user services that survive the uninstall. Orphan `rootlessport`/`conmon` processes hold port 8443 and block subsequent installs.

**Required:** `aba mirror uninstall` must handle:
- Stopping and disabling Quay systemd user services (`quay-app`, `quay-redis`, `quay-pod`)
- Killing orphan `rootlessport`/`conmon` processes
- Removing Quay data directories (`~/quay-install`, etc.)
- Verifying port 8443 is free after teardown

### 7. `aba` CLI Fails to Bootstrap Empty `aba.conf`

**Status:** Backlog  
**Priority:** Medium  
**Estimated Effort:** Small  
**Created:** 2026-02-21

**Problem:**
After `aba reset -f` or `./install`, calling `aba` with CLI flags that should configure `aba.conf` fails because the Makefile guard checks `ocp_version` before the CLI flags get a chance to write it:

```
Feb 21 06:33:44      >> aba --noask --platform vmw --channel stable --version p --base-domain p1.example.com
Makefile:116: *** "Value 'ocp_version' not set in aba.conf! Run aba in the root of Aba's repository or read the README.md file on how to get started.".  Stop.
```

**Fix:** The `aba` CLI should write config values to `aba.conf` before invoking `make`, or the Makefile guard should be deferred until an actual build target is invoked (not config-setting flags).

### 8. E2E Suite Teardown / Cleanup Independence

**Status:** Backlog  
**Priority:** Low  
**Estimated Effort:** Small  
**Created:** 2026-02-21

**Problem:**
Suites rely on the next suite's `setup_aba_from_scratch()` to clean up. There is no per-suite teardown. Issues:
- Running a single suite leaves state behind on conN
- The last suite in `--all` leaves state behind
- `suite-cluster-ops` and `suite-network-advanced` don't call `setup_aba_from_scratch` and could be affected by prior suite state
- `cleanup_all()` in `test/e2e/lib/setup.sh` is dead code (never called)

**Action:** Remove dead `cleanup_all()` or wire it into a teardown hook. Consider adding per-suite cleanup.

### 9. New Command: `aba status`

**Status:** Backlog  
**Priority:** Low  
**Estimated Effort:** Medium  
**Created:** 2026-02-21

**Problem:**
Users have no way to see how far along the aba setup pipeline they are.

**Proposed:**
A new `aba status` command that inspects existing state and shows pipeline progress:

```
$ aba status
aba.conf            OK  (version=4.16.12, channel=stable, platform=vmw)
vmware.conf         OK
mirror.conf         OK  (registry=registry.example.com:8443)
Mirror installed    OK
Mirror synced       OK  (last sync: 2026-02-20 14:30)
cluster.conf (sno)  OK  (nodes=1, network=10.0.1.0/24)
Cluster (sno)       NOT INSTALLED
```

### 10. Rename `CATALOG_CACHE_TTL_SECS` to `CATALOG_CACHE_TTL_MINS`

**Status:** Backlog  
**Priority:** Low  
**Estimated Effort:** Small  
**Created:** 2026-02-20

**Problem:**
The variable name `CATALOG_CACHE_TTL_SECS` is misleading if the value is typically in minutes. Rename for clarity.

### 11. E2E Framework: Graceful Stop / Signal Handling

**Status:** Backlog  
**Priority:** Low  
**Estimated Effort:** Medium  
**Created:** 2026-02-21

**Problem:**
There is no way to gracefully stop a running E2E test. No `trap` for SIGINT/SIGTERM, no PID file, no `--stop` command. When the main `run.sh` is killed, orphan SSH sessions on conN keep running. Stopping requires manually killing the local process and then SSHing to each conN to kill remaining processes.

**Proposed:**
- Add a `trap` in `run.sh` and `parallel.sh` to catch SIGINT/SIGTERM
- On signal: kill child SSH sessions, notify conN to stop, write a summary of what was interrupted
- Write a PID file so `run.sh --stop` can find and signal the running instance
- For parallel mode: propagate the stop signal to all pool dispatchers

---

## Completed

### E2E Suites: Refactor Embedded SSH to `e2e_run -h`
**Completed:** 2026-02-21
Converted ~46 embedded `ssh`/`_essh` calls across `suite-clone-and-check.sh` and `suite-mirror-sync.sh` to use the framework's `e2e_run -h "user@host"` / `e2e_run_remote` / `e2e_diag_remote` mechanisms. Commands now properly show `R` (remote) in logs with the target host displayed. Exceptions: pipe patterns (`local | ssh remote`), custom SSH key tests (`ssh -i`), and `_escp` (local scp) remain as `L`. Also fixed `e2e_diag` and `e2e_run_must_fail` to show `hostname -s` instead of hardcoded `localhost`. Added Golden Rule 14 to document this convention.

### E2E `--resume` Bug: Framework Clobbered Resume State
**Completed:** 2026-02-21  
`framework.sh` line 62 unconditionally set `E2E_RESUME_FILE=""`, overwriting the exported value from `run.sh`. Suites run via `bash "$suite_file"` (child process) source `framework.sh`, which wiped the resume file path before `e2e_begin_suite` could read it. Fixed by changing to `E2E_RESUME_FILE="${E2E_RESUME_FILE:-}"`.

### E2E Clone-and-Check: Inline Simple `_vm_*` Wrappers
**Completed:** 2026-02-21  
Replaced 5 trivial wrapper function calls (`_vm_remove_rpms`, `_vm_remove_pull_secret`, `_vm_remove_proxy`, `_vm_setup_vmware_conf`, `_vm_install_aba`) in `suite-clone-and-check.sh` with their actual `_essh`/`_escp` commands inline. Test logs now show the real ssh/scp commands instead of opaque function names. Functions remain in `pool-lifecycle.sh` for `create_pools` use.

### E2E Connected-Public: Missing `agentconf` Step
**Completed:** 2026-02-21  
`suite-connected-public.sh` "Proxy mode" test created `cluster.conf` via `aba cluster ... --step cluster.conf` but never ran `aba -d $SNO agentconf`, so `install-config.yaml` was never generated. The subsequent `assert_file_exists sno1/install-config.yaml` failed. Fixed by adding the missing `e2e_run "Generate agent config" "aba -d $SNO agentconf"` call.

### E2E Clone-and-Check: Permission and Assertion Fixes
**Completed:** 2026-02-21  
Fixed two test failures: (1) `sshd_config` grep needed `sudo` since the file is root-readable only on hardened RHEL; (2) `VC_FOLDER` assertion expected a pool-specific path pattern but the actual value was the shared datacenter folder. Relaxed to `grep -q 'VC_FOLDER=.'`.

### Systematic Script Directory Management Cleanup
**Completed:** 2026-02-19  
Cleaned up inconsistent `cd` patterns across 16+ scripts. Scripts now consistently trust Makefile CWD + symlinks per architecture principles.

### Validate starting_ip Is Within machine_network CIDR
**Completed:** 2026-02-18 (commit d190310)  
Added `ip_to_int`, `int_to_ip`, `ip_in_cidr` helpers to `scripts/include_all.sh`.  
`verify-cluster-conf()` now checks: starting_ip within CIDR, all nodes fit, VIPs within CIDR (non-SNO).
