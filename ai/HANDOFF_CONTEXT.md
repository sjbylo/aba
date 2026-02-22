# E2E Test Framework -- Handoff Context

> **Read this file + `ai/RULES_OF_ENGAGEMENT.md` at the start of every new session.**
> Last updated: January 25, 2026

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
