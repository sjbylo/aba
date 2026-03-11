# ABA Technical Backlog

This file tracks architectural improvements and technical debt that should be addressed in future releases.

---

## Medium Priority

### `aba install` Downloads Quay Binary Even When `reg_vendor=docker`

**Status:** Backlog
**Priority:** Medium
**Estimated Effort:** Small
**Created:** 2026-03-11

**Problem:**
Running `aba install` with `reg_vendor=docker` in `mirror.conf` downloads and extracts `mirror-registry-amd64.tar.gz` (the Quay appliance binary). This is wrong — Docker installs only need the Docker registry image, not the ~1GB Quay tarball. Wastes time and bandwidth.

**Root cause:**
In `templates/Makefile.mirror` line 230, `.available` has `mirror-registry` as an order-only prerequisite:
```makefile
.available: mirror.conf | .init .rpmsext mirror-registry
```
This runs the `mirror-registry` target (line 164, extracts Quay tarball) unconditionally before every install, regardless of `reg_vendor`.

**Proposed fix:**
Make the `mirror-registry` prerequisite conditional on vendor. Options:
- Use a Make conditional: `$(if $(filter quay auto,$(reg_vendor)),mirror-registry)`
- Or move the `ensure_quay_registry` call into `reg-install.sh` / `reg-install-quay.sh` and remove `mirror-registry` from the `.available` prerequisites entirely (let the script handle it)

**Where:** `templates/Makefile.mirror` line 230

### Deduplicate `aba isconf` output

**Status:** Backlog
**Context:** `aba isconf` generates both `sync/imageset-config-sync.yaml` and `save/imageset-config-save.yaml`. Each target independently calls `add-operators-to-imageset.sh`, producing duplicate operator listings in the output. The user sees the same operator list printed twice, which looks like a bug.
**Fix options:**
- Suppress verbose operator output on the second run (e.g. a `--quiet` flag to `add-operators-to-imageset.sh`)
- Consolidate: generate one base config then copy/adapt for sync vs save
- Simply note in the first run's output that both configs are being generated

### Option to preserve registry data on `aba uninstall`

**Status:** Backlog
**Context:** `aba uninstall` removes the Docker registry container/service AND deletes the data directory (e.g. `/home/steve/docker-reg`). Users may want to uninstall and reinstall without re-syncing/loading gigabytes of images.
**Proposed UX:**
```
[ABA] Uninstall Docker registry on localhost at bastion.example.com:8443? (Y/n): Y
[ABA] Also delete registry data at /home/steve/docker-reg? (y/N):
```
Default "No" for data deletion to be safe. This applies to Docker registries; Quay may have its own handling.

### Wrong path in mirror credential error message

**Status:** Partially done
**Context:** Main credential error message (reg-verify.sh lines 28-33) now uses user-facing commands. However, lines 41-42, 49, and 64 still reference `$regcreds_dir` and expose `~/.aba/mirror/` internal paths.

**Remaining:** Audit ALL `aba_abort` / `aba_warning` messages across `scripts/reg-*.sh` for any references to `$regcreds_dir` or `~/.aba/mirror/`. Replace with user-facing paths and commands.

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

### E2E: `create-bundle-to-disk` Leaves 57GB on conN After Cleanup

**Status:** Backlog (deferred -- re-apply if it recurs)
**Priority:** Medium
**Context:** The `suite-create-bundle-to-disk.sh` creates large bundles (OCP images in `mirror/save/`, oc-mirror caches) on conN, but its end-of-suite cleanup only cleans up on disN (remote). These artifacts remain on conN. Although the next suite's `aba reset -f` would clean it, a disk check at the end of the suite can fail.
**Fix:** Add conN self-cleanup (`aba reset -f` and `sudo find ~/ -type d -name .oc-mirror | xargs sudo rm -rf`) to the end-of-suite cleanup block in `test/e2e/suites/suite-create-bundle-to-disk.sh`.

---

## Low Priority

### Suppress `[ABA] Using .../mirror.conf file` for Simple Commands

**Status:** Backlog
**Priority:** Low
**Context:** Running `aba ls` (or other quick informational commands) outputs `[ABA] Using /home/steve/testing/aba/sno/mirror.conf file`, which is noise for the user. This message should be downgraded to `aba_debug` so it only appears with `-v`/verbose mode, or suppressed entirely for simple read-only commands like `ls`, `status`, `run --cmd`.

### E2E: default to git-based aba install, not local repo copy

**Status:** Backlog
**Priority:** Low
**Context:** `run.sh deploy` currently tars the entire local aba repo and scps it to conN. This is only needed by developers testing uncommitted changes. By default, the suites should install aba from git (the real user path), and `run.sh deploy` should only copy the test framework (`test/e2e/`).
**Proposed design:**
- Default: `run.sh deploy` copies only the test framework to conN. The suite setup step does `git clone`/`git pull` + `./install` to get aba -- testing the real user install path.
- `--local` flag: copies the full local repo (current behaviour) for developers testing uncommitted changes. Suite setup skips git clone since aba is already present.
- Benefits: tests the actual user journey, catches missing files in git, CI-ready.
- The suite setup step needs a conditional: if aba repo already exists (local deploy), use it; otherwise, git clone from the configured branch.

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

### 18. E2E `--resume` Remaining Bug (1 of 4)

**Status:** Backlog (bugs 2 & 3 fixed)  
**Priority:** Medium  
**Estimated Effort:** Small  
**Created:** 2026-03-03  
**Ref:** HANDOFF_CONTEXT.md §2

- ~~**Bug 2:** Fixed — `suite_begin` now copies resume file to `.resume` backup before truncating.~~
- ~~**Bug 3:** Fixed — `test_begin`/`test_end`/`e2e_run` now use `should_skip_checkpoint` and `_E2E_SKIP_BLOCK`.~~
- **Bug 4:** `--resume` not passed through dispatch — `_dispatch_suite` in run.sh doesn't append `--resume` to `runner_cmd`. Only restart mode passes it.

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

### 22. ~~Rename `.installed` / `.uninstalled` to `.available` / `.unavailable`~~

**Status:** Done (2026-03-06)  
**Priority:** Low  
**Estimated Effort:** Small  
**Created:** 2026-03-03  
**Ref:** E2E_FIXES_LOG.md B1

Done. Renamed all marker files from `.installed`/`.uninstalled` to `.available`/`.unavailable` across the codebase.

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

### ~~29. Docker Registry as First-Class Citizen~~

**Status:** Done (2026-03-10)  
**Created:** 2026-03-03  
**Ref:** ai/DESIGN-docker-registry-first-class.md

Done. Docker registry is now first-class: `reg-install-docker.sh`, `reg-uninstall-docker.sh`, remote install via `reg-install-remote.sh`, TUI support (Auto/Quay/Docker), `reg_vendor` config in `mirror.conf`, CLI `--vendor docker`.

### 31. Warn When Registry Data Directory Already Contains Data

**Status:** Backlog  
**Priority:** Medium  
**Estimated Effort:** Small  
**Created:** 2026-03-08

**Problem:**
When installing a Quay or Docker registry, if the destination `data_dir` already exists and contains data from a previous installation (or unrelated files), ABA silently proceeds. This can lead to confusing failures or data corruption.

**Proposed Fix:**
In `reg-install-quay.sh` and `reg-install-docker.sh` (and the remote variants), after `reg_setup_data_dir` resolves the path, check if the directory exists and is non-empty. If so, show a prominent red warning via `aba_warning`:
```bash
if [ -d "$data_dir" ] && [ "$(ls -A "$data_dir" 2>/dev/null)" ]; then
    aba_warning "Data directory '$data_dir' already exists and is not empty!" \
        "This may contain data from a previous registry installation." \
        "Proceeding will install on top of existing data."
fi
```
For remote installs, the check should run on the remote host via SSH.

### 32. Skip Remote Copy of Registry Tarball if Already Present (and valid)

**Status:** Backlog  
**Priority:** Low  
**Estimated Effort:** Small  
**Created:** 2026-03-08

**Problem:**
`reg-install-remote.sh` always copies `mirror-registry-amd64.tar.gz` (~1GB) to the remote host via `scp`, even if an identical copy already exists there from a previous install. The same may apply to the Docker registry image (`docker-reg-image.tgz`). On slow links this wastes significant time.

**Proposed Fix:**
Before copying, check if the file already exists on the remote host with a matching size (or checksum):
```bash
local_size=$(stat -c %s "$tarball")
remote_size=$(ssh "$remote" "stat -c %s '$remote_path' 2>/dev/null" || echo 0)
if [ "$local_size" != "$remote_size" ]; then
    scp "$tarball" "$remote:$remote_path"
fi
```
Or use `rsync --checksum` / `rsync --size-only` instead of `scp` for a one-line fix.

### 33. `verify` Target Runs Multiple Times Unnecessarily

**Status:** Backlog  
**Priority:** Medium  
**Estimated Effort:** Small  
**Created:** 2026-03-08

**Problem:**
When running `aba` commands, the Make `verify` target is executed multiple times in a row, which is unnecessary and wastes time. Need to investigate what triggers repeated `verify` runs and ensure it only executes once per invocation.

**Action:** Trace which Make dependency chains pull in `verify` and add appropriate sentinel files or order-only prerequisites to prevent redundant runs.

### 34. Mirror-Registry Install Files Sometimes Missing on Remote Host

**Status:** Backlog  
**Priority:** Medium  
**Estimated Effort:** Medium  
**Created:** 2026-03-08

**Problem:**
During remote Quay registry installation (`aba -d mirror install -H <host>`), the `mirror-registry` binary or its supporting files are sometimes not found on the remote host, causing `./mirror-registry: No such file or directory` errors. This has been seen on `registry4` and other hosts. The root cause may involve `run_once` markers persisting across `clean`/`reset` cycles, or files not being properly copied/extracted on the remote side.

**Action:** Make the remote install flow more robust:
- Verify the binary exists on the remote host before attempting to run it
- Re-copy/re-extract if missing, regardless of `run_once` state
- Add pre-flight checks in `reg-install-remote.sh`

### 38. `aba register` Should Validate Required Options Before Invoking Make

**Status:** Backlog  
**Priority:** Medium  
**Estimated Effort:** Small  
**Created:** 2026-03-08

**Problem:**
Running `aba register` without the required `--pull-secret-mirror` and `--ca-cert` flags produces a raw Make error:
```
[ABA] Error: pull_secret_mirror= is required (path to pull secret JSON file)
make: *** [Makefile:73: register] Error 1
```
The error comes from the Makefile recipe, not from `aba.sh`. The UX should catch missing required options early in `aba.sh` (before invoking `make`) and show a helpful message with correct usage, e.g.:
```
[ABA] Error: 'aba register' requires --pull-secret-mirror and --ca-cert options.
[ABA] Usage: aba -d mirror register --pull-secret-mirror <file> --ca-cert <file>
[ABA] See 'aba mirror --help' for details.
```

**Action:** In `aba.sh`, when `cur_target` is `mirror` and `BUILD_COMMAND` contains `register`, verify that `pull_secret_mirror=` and `ca_cert=` are present in `BUILD_COMMAND` before calling `eval make`. If missing, print usage and exit. The same pattern could apply to other targets that require specific options (e.g., `password` requiring `--reg-host`).

### 35. Consolidate `mirror/save` and `mirror/sync` Into `mirror/data`

**Status:** Backlog  
**Priority:** Medium  
**Estimated Effort:** Large  
**Created:** 2026-03-08

**Problem:**
The current split between `mirror/save/` and `mirror/sync/` directories adds complexity. Both hold imageset configs and oc-mirror workspace data for essentially the same purpose (getting images into the mirror registry). Consolidating them into a single `mirror/data/` directory would simplify the codebase, reduce user confusion, and eliminate duplicated imageset config generation logic.

**Action:** Design and implement the consolidation. Key considerations:
- Unified imageset config (currently separate `imageset-config-save.yaml` and `imageset-config-sync.yaml`)
- Backward compatibility for existing users with save/sync directories
- Impact on `aba save`, `aba load`, `aba sync` CLI commands
- Bundle workflow (save on connected side, load on disconnected side)

### 40. Improve `day2.sh` Screen Output and UX

**Status:** Backlog  
**Priority:** Medium  
**Estimated Effort:** Medium  
**Created:** 2026-03-08

**Problem:**
The `day2.sh` script output is noisy and hard to follow. Users see walls of `oc apply` output, raw YAML, and unclear progress indicators. The script should provide a cleaner, step-by-step experience showing what it's doing and whether each step succeeded.

**Action:** Review and improve `day2.sh` output:
- Clear step headers (e.g., "Step 1/4: Configuring OperatorHub...")
- Suppress raw `oc apply` output unless in debug mode
- Show success/failure status per step
- Summarize what was applied at the end

### 41. Improve Overall ABA UX and Screen Output

**Status:** Backlog  
**Priority:** Medium  
**Estimated Effort:** Large  
**Created:** 2026-03-08

**Problem:**
ABA's screen output across all commands could be more polished and user-friendly. Issues include:
- Inconsistent `[ABA]` prefix formatting (sometimes indented, sometimes missing)
- Raw `make` errors shown to users instead of friendly messages
- Internal paths (`~/.aba/...`) exposed in error messages
- Verbose output from underlying tools (curl, podman, oc-mirror) not suppressed in normal mode
- No clear progress indication for long-running operations
- No summary at completion of multi-step operations

**Action:** Systematic UX audit across all user-facing commands:
- Audit all `aba_abort`, `aba_warning`, `aba_info` messages for clarity and consistency
- Ensure `[ABA]` prefix is always left-justified (see backlog #16)
- Suppress tool output unless `--debug` is set
- Add progress indicators or step counters for long operations (sync, save, load, install)
- Wrap `make` errors with user-friendly messages in `aba.sh`
- Never expose internal paths to users (see "Wrong path in mirror credential error message")

### 36. CLI Download Retry Gaps

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

### 37. CLI Ensure Analysis — Add Ensures to 6 Scripts

**Status:** Backlog  
**Priority:** Low  
**Estimated Effort:** Medium  
**Created:** 2026-03-03  
**Ref:** ai/CLI_ENSURE_ANALYSIS.md

When moving logic out of Makefiles, add "ensure" patterns to 6 scripts as proposed in CLI_ENSURE_ANALYSIS.md.

---

## Completed

### `aba shutdown` Retry and Verify
**Completed:** 2026-03-10  
`cluster-graceful-shutdown.sh` has 3-attempt retry logic (lines 116-145) and verification via `make -s ls` when `wait=1` and `vmware.conf` exists.

### Suppress Curl Error Output During Registry Probing
**Completed:** 2026-03-10  
`probe_host()` in `include_all.sh` suppresses curl stderr during probing. ABA reports results in its own messaging.

### Mirror Config Flags Work With Named Mirror Directories (#17)
**Completed:** 2026-03-10  
`aba.sh` uses `$WORK_DIR/mirror.conf` dynamically. With `-d mymirror`, `WORK_DIR` points to the named mirror directory.

### E2E `_essh: command not found` in Framework Cleanup
**Completed:** 2026-03-10  
`runner.sh` sources `vm-helpers.sh` before `framework.sh`, making `_essh` available in cleanup paths.

### E2E Dispatcher: Detect Crashed Suites (#15)
**Completed:** 2026-03-10  
`_check_pool()` in `run.sh` has tmux session fallback: if no `.rc` file and tmux session is gone after 5s grace, returns 255 ("Suite died without writing .rc").

### Improve `.install.source` Breadcrumb File UX (#39)
**Completed:** 2026-03-10  
Renamed to `INSTALLED_BY_ABA.md` with verify/uninstall commands and date. Created by Quay, Docker, and remote install scripts.

### Rename `CATALOG_CACHE_TTL_SECS` to `CATALOG_CACHE_TTL_MINS` (#10)
**Status:** Won't fix  
Name is accurate — value is in seconds (`43200`), so `_SECS` suffix is correct.

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
