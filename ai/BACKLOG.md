# ABA Technical Backlog

This file tracks architectural improvements and technical debt that should be addressed in future releases.

---

## Medium Priority

### Suppress curl error output during registry probing

**Status:** Backlog
**Context:** Running `aba sync` (or any command that probes the mirror registry) shows raw curl errors to the user:
- `curl: (7) Failed to connect to bastion.example.com port 8443: Connection refused`
- `curl: (22) The requested URL returned error: 404`
- `curl: (22) The requested URL returned error: 401`

These are expected probe results (checking if registry is up), not real errors. The curl stderr should be suppressed (`2>/dev/null`) and ABA should report the result in its own messaging.

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

### 17. Mirror Config Flags Don't Work With Named Mirror Directories

**Status:** Backlog  
**Priority:** Medium  
**Estimated Effort:** Small  
**Created:** 2026-03-01

**Problem:**
All mirror config flags in `scripts/aba.sh` (`--vendor`, `--reg-host`, `--reg-port`, `--reg-user`, `--reg-password`, `--reg-path`, `--reg-ssh-key`, `--reg-ssh-user`, `--data-dir`) hardcode `$ABA_ROOT/mirror/mirror.conf`. When used with `-d <named-mirror>` (e.g. `aba -d mymirror --vendor auto install`), the flag writes to the default `mirror/mirror.conf` instead of `mymirror/mirror.conf`.

**Impact:** Only affects named mirror directories (new feature). Default `mirror/` works fine.

**Proposed Fix:**
Compute a `MIRROR_CONF_DIR` variable in `aba.sh` based on whether `WORK_DIR` points to a mirror directory:
```bash
if [ -f "$WORK_DIR/Makefile" ] && grep -q "mirror.conf" "$WORK_DIR/Makefile" 2>/dev/null && [ "$WORK_DIR" != "$ABA_ROOT" ]; then
    MIRROR_CONF_DIR=$WORK_DIR
else
    MIRROR_CONF_DIR=$ABA_ROOT/mirror
fi
```
Then replace all `$ABA_ROOT/mirror/mirror.conf` with `$MIRROR_CONF_DIR/mirror.conf` and `make -sC $ABA_ROOT/mirror` with `make -sC $MIRROR_CONF_DIR` in the 10 flag handlers. The `replace-value-conf` function already handles multiple files (skips non-existent), so a fallback pattern like `$MIRROR_CONF_DIR/mirror.conf $ABA_ROOT/mirror/mirror.conf` also works.

**Where:** `scripts/aba.sh` lines 373-433 (10 flag handlers)

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

### 5. Persistent Registry State in `~/.aba/mirror/`

**Status:** Completed  
**Completed:** Already implemented  
**Created:** 2026-02-21  

**Resolution:** Registry state (`state.sh`, `pull-secret-mirror.json`, `rootCA.pem`) is already persisted in `~/.aba/mirror/<name>/` via `reg-common.sh` `reg_post_install()`. This directory is outside the workspace and survives `aba reset -f`. The `regcreds_dir` is derived as `$HOME/.aba/mirror/$(basename "$PWD")` in `reg_load_config()`.

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

### 15. E2E Dispatcher: Detect Crashed Suites (No RC File)

**Status:** Backlog  
**Priority:** Medium  
**Estimated Effort:** Small  
**Created:** 2026-02-28

**Problem:**
`_check_pool()` in `run.sh` only detects suite completion by polling for `.rc` files.
If a suite crashes without writing an RC file (e.g., from a corrupted framework file,
OOM kill, or SSH disconnection), the dispatcher waits forever thinking the suite is
still running.

**Proposed Solution:**
Add a fallback liveness check: if no `.rc` file exists but the `e2e-suite-*` tmux
session is gone, treat the suite as crashed (exit=255). This prevents the dispatcher
from hanging indefinitely.

```bash
_check_pool() {
    local pool_num="$1" suite="$2"
    local rc_content
    rc_content=$(_ssh_con "$pool_num" "cat '${_RC_PREFIX}-${suite}.rc' 2>/dev/null" 2>/dev/null || true)
    if [ -n "$rc_content" ]; then
        echo "${rc_content//[^0-9]/}"
    else
        # Fallback: if tmux session is gone, suite crashed without writing RC
        local sess_exists
        sess_exists=$(_ssh_con "$pool_num" "tmux has-session -t 'e2e-suite-${suite}' 2>/dev/null && echo yes" 2>/dev/null || true)
        if [ -z "$sess_exists" ]; then
            echo "255"  # crashed
        fi
    fi
}
```

### 16. Audit All `[ABA]` Output for Left-Justification

**Status:** Backlog  
**Priority:** Low  
**Estimated Effort:** Medium  
**Created:** 2026-02-28

**Problem:**
Some `[ABA]` messages appear indented or mid-line rather than at column 0. The
expectation is that `[ABA]` is ALWAYS left-justified. In cases where the prefix
is not appropriate (e.g., sub-messages like "invalid!"), only the message string
should be output without the `[ABA]` prefix. In other cases, a `\n` is needed
before the message.

**Action:** Audit all `aba_log`, `echo "[ABA]"`, and similar patterns across
`scripts/*.sh` and `*/Makefile` to ensure consistent left-justification.

### 11. E2E Framework: Graceful Stop / Signal Handling

**Status:** Partially done  
**Priority:** Low  
**Estimated Effort:** Small (remaining)  
**Created:** 2026-02-21

**Done:**
- `run.sh stop` subcommand: SSHes to each conN, kills the runner PID from lock file, removes lock/rc files, kills tmux session.
- `runner.sh` has `trap 'rm -f "$LOCK_FILE"' EXIT` for lock cleanup.

**Remaining:**
- Add `trap` in `run.sh` coordinator for SIGINT/SIGTERM (propagate stop to conN)
- Write a PID file for `run.sh` itself so a second invocation can signal/stop the first
- Propagate stop signal to all pool dispatchers in parallel mode

---

## Unimplemented plans (from sessions)

*These were raised in sessions or other docs; added here so we don't forget them.*

### 18. E2E `--resume` Remaining Bugs (3 of 4)

**Status:** Backlog  
**Priority:** Medium  
**Estimated Effort:** Small  
**Created:** 2026-03-03  
**Ref:** HANDOFF_CONTEXT.md §2

- **Bug 2:** `suite_begin` truncates state file when resuming — same path for `E2E_STATE_FILE` and `E2E_RESUME_FILE`; truncate wipes checkpoints. Fix: copy to `.resume` backup before truncating.
- **Bug 3:** `test_begin`/`test_end` don't check resume checkpoint — only `run_test()` does. Fix: add skip-block in `test_begin`/`e2e_run`/`test_end` (see HANDOFF).
- **Bug 4:** `--resume` not passed through parallel dispatch — `_build_remote_cmd` in parallel.sh doesn't append `--resume`.

### 19. E2E dnsmasq Registry DNS Record

**Status:** Backlog  
**Priority:** Low  
**Estimated Effort:** Small  
**Created:** 2026-03-03  
**Ref:** HANDOFF_CONTEXT.md §3

`dig registry.pN.example.com +short` returns nothing on conN. `_vm_setup_dnsmasq` doesn't add a record for `registry.pN.example.com`. An incomplete fix exists in `git stash`.

### 20. E2E Error Suppression Audit (remaining files)

**Status:** Backlog  
**Priority:** Medium  
**Estimated Effort:** Small  
**Created:** 2026-03-03  
**Ref:** HANDOFF_CONTEXT.md §4

Audit `|| true` and `2>/dev/null` in: `test/e2e/lib/remote.sh`, `framework.sh`, `parallel.sh`, `config-helpers.sh`. Never silently swallow failures in test suites.

### 21. E2E Pool Affinity for Dispatch

**Status:** Backlog  
**Priority:** Low  
**Estimated Effort:** Medium  
**Created:** 2026-03-03  
**Ref:** HANDOFF_CONTEXT.md §6

Dispatcher assigns next suite to first free pool. Suites that share prerequisites (e.g. `cluster-ops` + `network-advanced` both use pool registry) could be chained to the same pool to reuse registry. Add lightweight chaining hints.

### 22. Rename `.installed` / `.uninstalled` to `.available` / `.unavailable`

**Status:** Backlog  
**Priority:** Low  
**Estimated Effort:** Small  
**Created:** 2026-03-03  
**Ref:** E2E_FIXES_LOG.md B1

With `REG_VENDOR=existing`, `.installed` is misleading. `.available` = "mirror registry ready for use". ~46 occurrences across ~18 files. Mechanical find-and-replace in a dedicated commit (after mirror --name / named dirs are stable).

### 23. Cluster VMs in Wrong vCenter Folder

**Status:** Backlog  
**Priority:** Low  
**Estimated Effort:** Small  
**Created:** 2026-03-03  
**Ref:** E2E_FIXES_LOG.md A

Compact/cluster VMs land in shared `abatesting` folder instead of pool-specific folder (e.g. `pool3/`). vCenter folder path during cluster creation should incorporate pool number.

### 24. `run.sh deploy --force` Confirmation Prompt

**Status:** Backlog  
**Priority:** Low  
**Estimated Effort:** Trivial  
**Created:** 2026-03-03

When using `deploy --force`, prompt user: "Really do this? (Y/N)?" to avoid accidental wipe of remote state.

### 25. E2E PAUSED State: Clear Flag File Promptly

**Status:** Backlog  
**Priority:** Low  
**Estimated Effort:** Trivial  
**Created:** 2026-03-03

Clear the PAUSED flag file as soon as it is reasonable so it doesn't persist and confuse status. Documented during run.sh status / interactive menu work.

### 26. E2E Spring-Clean Function

**Status:** Backlog  
**Priority:** Low  
**Estimated Effort:** Small  
**Created:** 2026-03-03

Function to remove state data and run verification routines to bring conN/disN back to a known good state (e.g. before a fresh full run or after debugging).

### 27. E2E `--loop` Option for Continuous Dispatch

**Status:** Backlog  
**Priority:** Low  
**Estimated Effort:** Medium  
**Created:** 2026-03-03

Option to continuously re-queue completed (or failed) suites so pools keep getting work without user re-running `reschedule`. Deferred in favor of one-shot retry + reschedule.

### 28. Investigate: Why Does `suite-connected-public` Install a Registry?

**Status:** Backlog  
**Priority:** Low  
**Estimated Effort:** Small  
**Created:** 2026-03-03

Suite only tests public registry path; clarify whether installing a reg is necessary or leftover. Add to backlog for investigation.

### 29. Docker Registry as First-Class Citizen (design)

**Status:** Backlog (design doc exists)  
**Priority:** Medium  
**Estimated Effort:** Large  
**Created:** 2026-03-03  
**Ref:** ai/DESIGN-docker-registry-first-class.md

Full design for consistent script layout, mirror.conf config, and TUI persistence for Docker registry. Status: PLANNED, not yet implemented.

### 31. CLI Download Retry Gaps

**Status:** Backlog  
**Priority:** Low  
**Estimated Effort:** Small  
**Created:** 2026-03-04

**Problem:**
Two gaps in CLI download retry coverage:

1. **`run_once` level:** If a CLI download/install task fails with a regular exit code (e.g., exit 1 from checksum failure or disk full), `run_once` records the failure and never retries. Only signal kills (exit 128-165) trigger automatic restart. A failed task stays failed until manually reset (`run_once -r`).

2. **`curl --retry` scope:** All downloads use `curl --retry 8` with default exponential backoff (1s, 2s, 4s... up to ~4 min total). However, `--retry` only covers transient HTTP errors (5xx, 408) and connection failures. HTTP 4xx errors (404, 403) are treated as permanent and not retried. Adding `--retry-all-errors` would cover these cases.

**Proposed Fix (if needed):**
- Add `--retry-all-errors` to curl invocations in `cli/Makefile` (trivial, one-line per call)
- Consider adding a `run_once -w --retry N` flag that clears exit state and restarts on non-zero exit (more complex, only if flaky failures recur)

**Current mitigation:** curl's `--retry 8` handles most transient issues. E2E test framework has its own `e2e_run -r` retry logic. Issue would only manifest during persistent CDN/mirror outages.

### 30. CLI Ensure Analysis — Add Ensures to 6 Scripts

**Status:** Backlog  
**Priority:** Low  
**Estimated Effort:** Medium  
**Created:** 2026-03-03  
**Ref:** ai/CLI_ENSURE_ANALYSIS.md

When moving logic out of Makefiles, add "ensure" patterns to 6 scripts as proposed in CLI_ENSURE_ANALYSIS.md.

---

## Completed

### `run.sh verify` -- Pool Verification Subcommand
**Completed:** 2026-03-02  
Extracted `_verify_con_vm()` / `_verify_dis_vm()` into standalone functions in `setup-infra.sh`. Added `--verify` flag to `setup-infra.sh` and `verify` subcommand to `run.sh`. Supports `--pool N` for single-pool checks. Streaming output (no hang), separate per-VM logs, `_fail()` helper with bold red output, summary table with failure reasons. Auto-detects pool count from `pools.conf`.

### Dynamic Suite Dispatcher (Work-Queue Model)
**Completed:** 2026-03-02  
`run.sh` dispatches one suite at a time to free pools, polls for completion, and assigns the next from the queue. Added `reschedule` subcommand to re-queue completed suites. Full CLI rationalization with consistent subcommand+flag structure.

### Simplify E2E Suite Regcreds Setup With `aba register`
**Completed:** 2026-03-02  
Refactored `suite-airgapped-existing-reg.sh` to use `aba -d mirror register` with the pool registry on conN instead of manual `mkdir`/`cp` of credentials. Also added `aba -d mirror unregister` core command for externally-managed registries.

### E2E Suite Banner in tmux on Dispatch
**Completed:** 2026-02-23  
`runner.sh` now prints a large `####` banner with suite name, pool number, hostname, and timestamp before each suite starts. Makes it easy to find suite boundaries when scrolling tmux scrollback.

### E2E Clone-Check: Parallelize VM Cloning and Configuration
**Completed:** 2026-02-22  
`setup-infra.sh` Phase 1 clones all conN in parallel (background `&` + `wait`), then all disN. Phase 2 runs `_configure_con_vm` and `_configure_dis_vm` in parallel per pool. disN waits for conN NAT internally.

### E2E VM Reuse: Snapshot-Based Fast Restart
**Completed:** 2026-02-22  
Implemented via `pool-ready` snapshots. `setup-infra.sh` reverts existing VMs instead of re-cloning when the snapshot exists, and skips configuration. `runner.sh` reverts disN to `pool-ready` before each suite.

### `imagesetconf` with `op-sets=all` Missing Catalog
**Completed:** 2026-02-23  
Verified working: `add-operators-to-imageset.sh` (lines 122-130) correctly writes the `redhat-operator-index` catalog for `op-sets=all`. E2E test in `suite-create-bundle-to-disk.sh` verifies it. Original report was likely a transient test environment issue.

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
