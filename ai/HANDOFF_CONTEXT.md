# E2E Test Framework -- Handoff Context

> **Read this file + `ai/RULES_OF_ENGAGEMENT.md` at the start of every new session.**
> Last updated: 2026-03-01

## Learnings from coding session (for E2E session)

The following was captured from the **coding/refactor** chat so the E2E session has full context. This chat does **not** do test monitoring or E2E dispatch; that stays in the E2E chat.

### ABA flow and DISCO model (core to ABA)
- ABA **always** starts on a **CONNECTED** workstation. It downloads needed files/images (including Docker mirror tar, CLIs, etc.).
- The ABA repo is then copied or archived (e.g. `backup.sh`) into an **ABA Bundle** that is moved to a **fully disconnected (DISCO)** environment.
- **DISCO has NO internet by design.** All required deps, files, and images **must** be inside the ABA bundle. If something assumes "reach internet on disN to fetch X", that is **wrong** — fix the bundle/content, not the test.
- Reference: [Red Hat Developer blog: Simplify OpenShift installation in air-gapped environments](https://developers.redhat.com/articles/2025/10/14/simplify-openshift-installation-air-gapped-environments). See also the ABA flow diagram (Figure 1 there).

### Nomenclature
- **Do not** use `conN` or `disN` in ABA core code (`aba.sh`, `mirror/Makefile`, etc.). Those are E2E test suite host names; ABA users do not know them. Use "localhost", "remote host", "registry host", etc. in messages and comments.

### Bundle / tar transfer
- The bundle (tar) transfer **only** copies ABA repo files. It does **not** copy `~/.vmware.conf` or other files outside the repo. E2E/infra must set those up on the target host.

### Day 2 rule
- **Always** run `aba day2` **after** loading or syncing images to the mirror (to update from oc-mirror cluster file dir). Suites that load/sync and then use the cluster must run day2 before relying on OperatorHub/mirror config.

### E2E suite rules (in RULES_OF_ENGAGEMENT; summarized here)
- **No suite** ever installs a cluster (or mirror) and leaves it for another suite. **Only** the OOB cluster (and OOB pool registry) can be shared across suites.
- A suite **always** cleans up the resources it installed (mirrors and clusters). Cleanup runs at suite end; next suite’s pre-suite cleanup also cleans everything under `~/aba` (leftover .cleanup files). If the previous suite finished or crashed, it is safe to clean — no "is this still needed?" guard.
- **OOB cluster** must **not** be deleted from inside a test suite. Suites only delete what they created (e.g. compact/standard); SNO can be shut down, not deleted (small, useful for debugging).
- **No safety nets** in test suites. If something is wrong, fix the suite or infra; do not add fallback cleanup or skip logic that hides bugs.
- **Prefer** documentation as **comments inside the code** over extra files under `ai/` when it fits.

### Mirror config flags and named mirror dirs (backlog)
- `--vendor`, `--reg-host`, `--reg-port`, etc. in `aba.sh` **hardcode** `$ABA_ROOT/mirror/mirror.conf`. With `-d &lt;named-mirror&gt;` (e.g. `aba -d mymirror --vendor auto install`) the flag still writes the default mirror. **Default `mirror/` works.** Fix is in backlog #17 (compute `MIRROR_CONF_DIR` from `WORK_DIR`). Do not use `$ABA_ROOT` outside `aba.sh`/TUI (see DECISIONS).

### Script architecture ($ABA_ROOT)
- `$ABA_ROOT` may **only** be used in `scripts/aba.sh` and `tui/abatui.sh`. All other scripts use `cd` to repo root and relative paths. Test: `test/func/test-aba-root-only-in-aba-sh.sh`.

### Recent commits (coding session)
- `aba mirror --name` + existing-registry **register** (pull secret + CA cert → regcreds, `REG_VENDOR=existing`, safe uninstall). Setup flow matches `aba cluster --name` (dir + Makefile + init + mirror.conf edit prompt).
- `create-mirror-conf.sh`: edit prompt now shows `$(basename $PWD)/mirror.conf` (e.g. `xxxx/mirror.conf`) instead of hardcoded `mirror/mirror.conf`.
- Backlog: #17 mirror config flags for named dirs, #18 E2E regcreds via `aba register`, B1 rename `.installed`/`.uninstalled` to `.available`/`.unavailable`.

### Retries and cleanup in E2E
- Cluster installs/bootstrap use **single retry** (`-r 1`). No delete+recreate between attempts (ABA resumes from marker files).
- "Attempt (X/Y) failed" lines now append " - attempting again..." when a retry will follow.
- Runner cleanup uses `aba -y -d … uninstall` / `aba -y -d … delete` so automation is never blocked by prompts.

### Notifications
- Notifications (e.g. notify.sh) were improved: prefix `[e2e]`, include pool number and test name, last ~20 lines of suite log for failures, actual hostname (not "localhost"). No duplicate info in the message body.

### Test suite don’ts
- **Never** "skip the remote test gracefully" or similar. Suites must fail if preconditions are not met; fix the environment or the test, do not paper over.
- For Docker registry tests: verify **all** configured values (user, password, data dir, port, path, etc.), not just that install/verify/uninstall ran.

---

## What We're Doing

Fixing and hardening the E2E test framework in `test/e2e/`. The primary directive:

> "Keep running and fixing the **test code** suites. Document any proposed ABA/TUI core changes but do NOT implement them directly."

## Current Backlog (Priority Order)

### 1. Deploy updated code and re-run failed suites

- rsync updated `~/aba/` to con1 and con2 (with proper excludes: `mirror/`, `cli/` binaries/tarballs)
- Re-run previously failed suites **without** `--clean`:
  - con1: `network-advanced` (was failing due to missing oc-mirror -- now self-managed)
  - con2: `mirror-sync` (was failing due to CIDR bug -- now fixed)
  - Investigate `create-bundle-to-disk` on con2 if it also failed

### 2. `--resume` Fix (3 remaining bugs of 4)

Bug 1 is done (committed). Bugs 2-4 remain:

**Bug 2: `suite_begin` truncates state file when resuming**
- File: `test/e2e/lib/framework.sh` line ~284
- `E2E_STATE_FILE` and `E2E_RESUME_FILE` point to the same path (`<suite>.state`). `suite_begin` does `: > "$E2E_STATE_FILE"` which wipes previous checkpoint data before any test can check it.
- Fix: When resuming, copy existing state file to a `.resume` backup, set `E2E_RESUME_FILE` to that backup, then truncate the state file for the new run.

**Bug 3: `test_begin`/`test_end` don't check resume checkpoint**
- File: `test/e2e/lib/framework.sh`
- Only `run_test()` calls `should_skip_checkpoint`. But suites like `clone-and-check` use `test_begin`/`test_end` with `e2e_run` calls between them.
- Fix: Add skip-block mechanism:
  - `test_begin` checks `should_skip_checkpoint`; if passed before, set `_E2E_SKIP_BLOCK=1`
  - `e2e_run` early-returns if `_E2E_SKIP_BLOCK` is set
  - `test_end` clears the flag

**Bug 4: `--resume` not passed through parallel dispatch**
- File: `test/e2e/lib/parallel.sh` line ~126
- `_build_remote_cmd` never includes `--resume` in the remote SSH command.
- Fix: Append `--resume` when `CLI_RESUME` is set.

### 3. dnsmasq Registry DNS Record

- `dig registry.p1.example.com +short` returns nothing on con1
- `_vm_setup_dnsmasq` in `test/e2e/lib/pool-lifecycle.sh` doesn't add a record for `registry.pN.example.com`
- There is a **stashed** incomplete fix: `git stash list` will show it. It started adding `dis_vlan_ip` but didn't add the actual DNS record to the dnsmasq config.

### 4. Error Suppression Audit (remaining files)

User directive: "Stop silently swallowing failures in TEST SUITES!!!! OMG!"

- `test/e2e/lib/remote.sh` -- audit `|| true` and `2>/dev/null`
- `test/e2e/lib/framework.sh`, `parallel.sh`, `config-helpers.sh` -- review suppressions
- `pool-lifecycle.sh` was already cleaned up in a prior session

### 5. Bare-metal Output Assertion (done, committed)

Already committed: `suite-mirror-sync.sh` now captures `aba install` output and greps for expected messages ("Check & edit", "Boot your servers") instead of just checking flag files.

### 6. Pool affinity for parallel dispatch (future optimization)

Currently the work-queue dispatcher assigns the next suite to whichever pool becomes free first. Suites that share a prerequisite (e.g. `cluster-ops` and `network-advanced` both use `setup-pool-registry.sh`) may land on different pools, causing redundant Quay installs + oc-mirror syncs.

Option B (preferred): add lightweight chaining hints so the dispatcher prefers dispatching `network-advanced` to the same pool that already ran `cluster-ops`. Preserves suite independence while maximizing registry reuse.

Low priority -- current overhead is ~30 min extra per parallel run. Worth revisiting when scaling to 3-4 pools.

## Key Rules & Decisions

### disN Internet Access
> **RULE: disN should not have internet access and should not need it, unless maybe for RPMs, which MUST be installed before the tests run!**

- `_vm_disconnect_internet` removes default gateway from disN after setup
- `_vm_setup_time` replaces `/etc/chrony.conf` entirely (only `10.0.1.8` NTP)
- disN can still reach conN via VLAN for local services

### Error Handling in Tests
- NEVER use `2>/dev/null` in test commands
- NEVER use `|| true` in test commands
- If a command can legitimately fail, use explicit precondition checks
- See "E2E Golden Rules" in `ai/RULES_OF_ENGAGEMENT.md`

### File Modification Permissions
- **CAN modify freely**: `test/e2e/*`, `test/func/*`, `tui/*`, `ai/*`
- **Ask first**: `scripts/include_all.sh`, `scripts/aba.sh`
- **Don't touch**: everything else (unless explicitly requested)

## How to Run Tests

```bash
# From the coordinator (registry4 or new dev VM):
cd /home/steve/aba

# Run all E2E suites in parallel across pools:
nohup test/e2e/run.sh --parallel --all --clean 2>&1 &

# Run a single suite:
test/e2e/run.sh --suite cluster-ops

# List available suites:
test/e2e/run.sh --list

# Check logs:
tail -f test/e2e/logs/latest.log
cat test/e2e/logs/summary.log
```

**Important**: Run tests detached (`nohup`) from Cursor's terminal -- Cursor crashes kill SSH connections which kill remote test processes.

## Architecture Quick Reference

```
test/e2e/
├── run.sh              # Main entry point (CLI parsing, dispatch)
├── pools.conf          # Pool definitions (pool1=con1+dis1, pool2=con2+dis2)
├── config.env          # Default test parameters
├── lib/
│   ├── framework.sh    # Core: e2e_run, suite/test lifecycle, checkpoint/resume
│   ├── parallel.sh     # Work-queue dispatcher for multi-pool parallel runs
│   ├── remote.sh       # SSH helpers for con/dis bastion commands
│   ├── pool-lifecycle.sh  # VM cloning, network, NTP, firewall, dnsmasq setup
│   └── config-helpers.sh  # IP/domain/cluster-name helpers per pool
├── suites/
│   ├── suite-clone-and-check.sh      # [infra] Provisions pool VMs
│   ├── suite-cluster-ops.sh          # Main cluster install/day2/lifecycle
│   ├── suite-mirror-sync.sh          # Mirror sync + bare-metal flow
│   ├── suite-airgapped-local-reg.sh  # Airgapped with local registry
│   ├── suite-airgapped-existing-reg.sh  # Airgapped with existing registry
│   └── ...
└── logs/               # Runtime logs and state files
```

## Git State

- Branch: `dev`
- Remote: `origin` -> `https://github.com/sjbylo/aba.git`
- There is a `git stash` with an incomplete dnsmasq fix (backlog item 2)
- All committed work is pushed

## Dev Environment

- **Old dev VM**: registry4.example.com (amd64) -- being replaced
- **New dev VM**: 192.168.150.136 (arm64) -- should work fine, all heavy work runs on remote amd64 VMs via SSH
- **Pool 1**: con1.example.com + dis1.example.com
- **Pool 2**: con2.example.com + dis2.example.com
