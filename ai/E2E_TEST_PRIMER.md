# E2E Test Primer

Complete guide to the ABA end-to-end test framework. Covers architecture,
day-to-day operations, writing suites, and troubleshooting.

---

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Lab Infrastructure](#lab-infrastructure)
4. [Configuration](#configuration)
5. [Day-to-Day Operations](#day-to-day-operations)
6. [Infrastructure Management](#infrastructure-management)
7. [Suite Lifecycle](#suite-lifecycle)
8. [Writing a New Suite](#writing-a-new-suite)
9. [The Interactive Prompt](#the-interactive-prompt)
10. [Cleanup Model](#cleanup-model)
11. [Existing Suites](#existing-suites)
12. [Dispatcher Internals](#dispatcher-internals)
13. [Troubleshooting](#troubleshooting)
14. [Golden Rules](#golden-rules)

---

## Overview

The E2E framework validates ABA across isolated vSphere pools. Each pool
contains a **connected bastion** (`conN`) with internet access and a
**disconnected bastion** (`disN`) that simulates an air-gapped environment.
A coordinator machine runs `run.sh` which deploys test harnesses to each
pool and dispatches suites in parallel.

Key files:

```
test/e2e/
├── run.sh              # Coordinator: CLI, deploy, dispatch, monitoring
├── runner.sh           # Runs on conN: suite execution, cleanup, result reporting
├── setup-infra.sh      # VM provisioning: golden, clone, configure, snapshot
├── pools.conf          # Pool definitions (one line per pool)
├── config.env          # Default test parameters, IPs, MACs
├── lib/
│   ├── constants.sh    # Shared path/name constants
│   ├── framework.sh    # Core: e2e_run, plan_tests, test_begin/end, cleanup
│   ├── remote.sh       # SSH helpers, VM cloning (govc)
│   ├── setup.sh        # Bastion setup, pre-suite cleanup helpers
│   ├── vm-helpers.sh   # VM configuration (network, DNS, firewall, packages)
│   ├── config-helpers.sh  # Per-pool IP/domain/cluster-name helpers
│   └── pool-lifecycle.sh  # Pool create/destroy/configure orchestration
└── suites/
    └── suite-*.sh      # Individual test suites
```

---

## Architecture

```
Coordinator (run.sh on bastion/dev machine)
  │
  ├── SSH ──> con1 ──> runner.sh (tmux: e2e-suite)
  │             ├── SSH ──> dis1 (air-gapped bastion)
  │             └── SSH ──> cluster VMs (via aba ssh)
  │
  ├── SSH ──> con2 ──> runner.sh (tmux: e2e-suite)
  │             ├── SSH ──> dis2
  │             └── SSH ──> cluster VMs
  │
  └── SSH ──> con3 ──> runner.sh (tmux: e2e-suite)
                ├── SSH ──> dis3
                └── SSH ──> cluster VMs
```

**Coordinator (`run.sh`)** -- runs on the developer's machine or a dedicated
bastion. Handles CLI parsing, VM infrastructure (via `setup-infra.sh`),
harness deployment (scp), suite dispatching across pools, result collection,
and the monitoring dashboard.

**Runner (`runner.sh`)** -- runs inside a tmux session on each `conN`. Handles
pre-suite cleanup (disN reset, stale container removal), suite execution,
post-suite integrity checks, and writes result codes to `/tmp/e2e-suite-<name>.rc`.

**Suites (`suite-*.sh`)** -- each suite is a self-contained bash script that
uses the framework functions (`plan_tests`, `test_begin`, `e2e_run`, `test_end`,
`suite_end`) to define and execute test steps.

---

## Lab Infrastructure

### Network Segments

| Segment | CIDR | Purpose |
|---------|------|---------|
| Lab / Machine Network | 10.0.0.0/20 | Shared L2 for bastions + cluster VMs (ens192) |
| Pool Subnet | 10.0.2.0/24 | Per-pool "decade" IPs within the lab |
| VLAN | 10.10.20.0/24 | conN-to-disN link, VLAN cluster tests (ens224.10) |
| Internet | DHCP | conN only, via ens256 |

### Per-Pool IP Allocation

Each pool gets a "decade" of IPs in 10.0.2.0/24:

```
Offset   Role                 Example (Pool 1)
  .x0    conN bastion (DHCP)  10.0.2.10
  .x1    disN bastion (DHCP)  10.0.2.11
  .x2    Cluster node / SNO   10.0.2.12
  .x3    API VIP              10.0.2.13
  .x4    Apps VIP             10.0.2.14
  .x5-9  Additional nodes     10.0.2.15-19
```

### Host Roles

**conN (connected bastion)**
- Internet-connected RHEL VM; runs `runner.sh` in tmux
- Hosts dnsmasq (cluster DNS for `*.pN.example.com`)
- Pool registry on port 8443 (pre-populated with OCP images)
- NAT gateway for disN's VLAN traffic

**disN (disconnected bastion)**
- Air-gapped RHEL VM; no direct internet (ens256 disabled)
- Used for disconnected/airgapped tests (mirrors, bundles, clusters)
- DNS points to conN's VLAN IP

### NIC Layout (3 NICs per VM)

| NIC | Interface | conN | disN |
|-----|-----------|------|------|
| ethernet-0 | ens192 | Lab network (DHCP) | Lab network (DHCP) |
| ethernet-1 | ens224.10 | VLAN (static) | VLAN (static) |
| ethernet-2 | ens256 | Internet (DHCP) | Exists but disabled |

### vSphere Layout

```
/Datacenter/vm/aba-e2e/
├── golden/
│   └── aba-e2e-golden-rhel8     (snapshot: golden-ready)
├── pool1/
│   ├── con1                     (snapshot: pool-ready)
│   ├── dis1                     (snapshot: pool-ready)
│   └── <cluster VMs created by suites>
├── pool2/
│   ├── con2, dis2               (snapshot: pool-ready)
└── pool3/
    ├── con3, dis3               (snapshot: pool-ready)
```

---

## Configuration

### config.env -- Global Defaults

Key variables (see `test/e2e/config.env` for full list):

| Variable | Default | Purpose |
|----------|---------|---------|
| `TEST_CHANNEL` | `stable` | OCP release channel |
| `OCP_VERSION` | `p` | `p`=previous, `l`=latest, or explicit `x.y.z` |
| `INT_BASTION_RHEL_VER` | `rhel8` | RHEL version for disN VMs |
| `CON_SSH_USER` | `steve` | SSH user for conN |
| `DIS_SSH_USER` | `steve` | SSH user for disN |
| `VM_BASE_DOMAIN` | `example.com` | Base domain for all VMs |
| `VMWARE_CONF` | `~/.vmware.conf` | govc credentials file |
| `KVM_CONF` | `~/.kvm.conf` | KVM/libvirt config for KVM suites |
| `OPERATOR_WAIT_TIMEOUT` | `1800` | Seconds to wait for cluster operators |
| `SSH_WAIT_TIMEOUT` | `300` | Seconds to wait for SSH availability |

**Precedence**: CLI flags > pool overrides in `pools.conf` > `config.env`

### pools.conf -- Pool Definitions

One line per pool. Format:

```
POOL_NAME  CONNECTED_HOST  INTERNAL_HOST  INTERNAL_VM_NAME  [KEY=VAL ...]
```

Example:

```
pool1  con1  dis1  aba-e2e-template-rhel8  INT_BASTION_RHEL_VER=rhel8  POOL_NUM=1  VM_DATASTORE=Datastore4-1  VC_FOLDER=/Datacenter/vm/aba-e2e/pool1
pool2  con2  dis2  aba-e2e-template-rhel8  INT_BASTION_RHEL_VER=rhel8  POOL_NUM=2  VM_DATASTORE=Datastore4-2  VC_FOLDER=/Datacenter/vm/aba-e2e/pool2
pool3  con3  dis3  aba-e2e-template-rhel8  INT_BASTION_RHEL_VER=rhel8  POOL_NUM=3  VM_DATASTORE=Datastore4-3  VC_FOLDER=/Datacenter/vm/aba-e2e/pool3
```

`KEY=VAL` pairs are exported into the runner's environment for that pool.

---

## Day-to-Day Operations

All commands run from `test/e2e/`.

### Starting a Full Test Run

```bash
# Run all suites across 3 pools
./run.sh run --all --pools 3

# Same, but deploy the local ABA source code to conN hosts
./run.sh run --all --pools 3 --dev
```

### Running a Single Suite

```bash
# Run one suite on one pool
./run.sh run --suite cluster-ops --pool 2

# Force re-run (clear previous state for that suite/pool)
./run.sh run --suite cluster-ops --pool 2 --force
```

### Monitoring

```bash
# Quick status table
./run.sh status

# Dashboard (read-only tmux, tails summary logs)
./run.sh dash

# Live view (interactive tmux, attaches to runner sessions)
./run.sh live

# Attach to a specific pool's runner tmux
./run.sh attach con1
```

### Deploying Code Changes

```bash
# Deploy test harness (lib/, suites/, runner.sh, config) to all pools
./run.sh deploy --pools 3

# Force deploy even if a suite is running (hot-deploy)
./run.sh deploy --force --pools 3

# Deploy harness + ABA source code
./run.sh deploy --dev --pools 3
```

### Stopping and Restarting

```bash
# Stop all pools (kills tmux + dispatcher)
./run.sh stop --pools 3

# Stop a single pool (dispatcher keeps running)
./run.sh stop --pool 2

# Restart: stop, redeploy, re-run last suite
./run.sh restart --pools 3

# Restart with resume (skip already-passed tests)
./run.sh restart --pool 1 --resume
```

### Queue Management

```bash
# Inject a suite into the running dispatcher's queue (front priority)
./run.sh reschedule --suite kvm-lifecycle

# List available suites
./run.sh list
```

### VM Power Control

```bash
# Power on all pool VMs
./run.sh start --pools 3

# Power on a single pool
./run.sh start --pool 2

# Destroy pool VMs (with cleanup of clusters/mirrors first)
./run.sh destroy --pools 3 --clean
```

---

## Infrastructure Management

### Creating Pool VMs from Scratch

`setup-infra.sh` handles the full provisioning pipeline:

```bash
# Create/verify all pool VMs (reuses existing if SSH works)
bash setup-infra.sh --pools 3

# Force recreate pool VMs from the golden snapshot
bash setup-infra.sh --pools 3 --recreate-vms

# Also rebuild the golden VM from the template
bash setup-infra.sh --pools 3 --recreate-golden --recreate-vms
```

**Phases:**

| Phase | Action |
|-------|--------|
| 0 | Build golden VM from template, configure, snapshot `golden-ready` |
| 1 | Clone conN/disN from golden (linked clone at `golden-ready`). Reuse if VM exists + SSH works; revert to `pool-ready` if SSH fails; destroy + reclone if broken. |
| 2 | Configure each VM (network, DNS, firewall, packages, users, SSH keys) |
| 3 | Power off, snapshot `pool-ready`, power on |

### Reverting VMs to Clean State

If VMs exist but are in a bad state:

```bash
# setup-infra.sh auto-reverts broken VMs to pool-ready
bash setup-infra.sh --pools 3
```

If VMs are just powered off:

```bash
./run.sh start --pools 3
# Wait ~30s for SSH
./run.sh deploy --force --pools 3
./run.sh run --all --pools 3
```

### Snapshot Names

| Snapshot | On | Created by | Purpose |
|----------|----|------------|---------|
| `golden-ready` | Golden VM | setup-infra.sh Phase 0 | Source for pool clones |
| `pool-ready` | Each conN/disN | setup-infra.sh Phase 3 | Clean baseline for test runs |

---

## Suite Lifecycle

Every suite follows this lifecycle:

```
suite_begin "suite-name"
  │
  plan_tests "Test A" "Test B" "Test C"
  │
  ├── test_begin "Test A"
  │     e2e_run "step 1" "command1"
  │     e2e_run "step 2" "command2"
  │   test_end
  │
  ├── test_begin "Test B"
  │     e2e_run -r 3 2 "step with retries" "command3"
  │     e2e_run_remote "step on disN" "command4"
  │   test_end
  │
  └── test_begin "Test C"
        e2e_run "cleanup" "command5"
      test_end
  │
  suite_end
```

### Framework Functions

**`suite_begin "name"`** -- Initialize suite: create log files, reset counters,
set up checkpoint file.

**`plan_tests "name1" "name2" ...`** -- Declare the test plan. Prints a progress
table showing PENDING for each test. Updated in real-time as tests run.

**`test_begin "name"`** -- Start a test block. Marks the plan row as RUNNING.
If resuming and this test already passed, it returns early (DONE).

**`test_end [rc]`** -- End a test block. Updates PASS/FAIL/SKIP count, plan
row, summary log, and checkpoint file.

**`e2e_run [flags] "description" command...`** -- Execute a command with retries.

| Flag | Default | Purpose |
|------|---------|---------|
| `-r RETRIES BACKOFF` | `5`, `1.5` | Max attempts and backoff multiplier |
| `-d DELAY` | `5` | Initial delay between retries (seconds) |
| `-m MAX_DELAY` | `60` | Cap on backoff delay |
| `-h HOST` | (local) | Run via SSH on HOST |
| `-q` | off | Quiet: log only, no terminal echo |

On failure after all retries, triggers the interactive prompt (if
`_E2E_INTERACTIVE=1`, which runner.sh always sets).

**`e2e_run_remote "description" command...`** -- Shorthand for
`e2e_run -h "$INTERNAL_BASTION"` (runs on disN).

**`suite_end`** -- Print final totals, reprint progress table, send
notification. Returns 1 if any test failed, 0 otherwise.

### Checkpoint / Resume

Each test result is appended to `E2E_STATE_FILE`:

```
0 Test A          # passed
0 Test B          # passed
SKIP Test C       # skipped
```

When `--resume` is used, `runner.sh` sets `E2E_RESUME_FILE` to the previous
state file. `test_begin` checks it and skips tests that already show `0`
(passed), allowing a suite to resume from where it left off.

---

## Writing a New Suite

### Template

Create `test/e2e/suites/suite-my-feature.sh`:

```bash
#!/bin/bash
# Suite: My Feature -- description of what this tests

source "$(dirname "$0")/../lib/framework.sh"

suite_begin "my-feature"

plan_tests \
	"Setup: install aba and configure" \
	"Feature: test the main workflow" \
	"Cleanup: delete cluster and unregister mirror"

# --- Setup ---
test_begin "Setup: install aba and configure"

	e2e_run "Install ABA from git" \
		"cd ~/aba && git pull && ./install"

	e2e_run "Configure ABA" \
		"aba --channel stable --version \$(cat /tmp/e2e-ocp-version) --platform vmw"

test_end

# --- Feature test ---
test_begin "Feature: test the main workflow"

	e2e_run "Sync images to registry" \
		"aba -d mirror sync"

	e2e_run -r 3 2 "Install SNO cluster" \
		"aba cluster --name sno --type sno --step install"

	# Register for cleanup so the cluster gets deleted even if the suite crashes
	e2e_add_to_cluster_cleanup "sno"

	e2e_run "Verify cluster health" \
		"cd sno && . <(aba shell) && oc get co"

test_end

# --- Cleanup ---
test_begin "Cleanup: delete cluster and unregister mirror"

	e2e_run "Delete cluster" \
		"aba --dir sno delete -y"

	e2e_run "Unregister mirror" \
		"aba -d mirror unregister"

test_end

suite_end
```

### Key Conventions

- Suite filename must match `suite-<name>.sh`
- `plan_tests` names must exactly match `test_begin` names
- Register clusters and mirrors for cleanup early (before they could fail)
- Cleanup tests should be the last test block
- Use `e2e_run_remote` for commands on disN
- Use `-r` flag for commands that are known to be flaky

---

## The Interactive Prompt

When a command fails after all retries (and `_E2E_INTERACTIVE=1`), the
runner presents an interactive prompt:

```
Suite: cluster-ops | TEST [3]: SNO install | Step: Install cluster
FAILED: "exit=1" aba cluster --name sno --type sno --step install
[R]etry [s]kip [S]kip-suite [0]restart-suite [c]leanup [a]bort [p]ause [!cmd] (20m timeout):
```

| Key | Action | Effect |
|-----|--------|--------|
| `R` / Enter | Retry | Re-run the full `e2e_run` retry loop |
| `s` | Skip step | Mark step as skipped (user), continue suite |
| `S` | Skip suite | Mark suite as skipped, exit with code 3 |
| `0` | Restart suite | Exit with code 4, runner restarts from the top |
| `c` / `C` | Cleanup | Run cluster + mirror cleanup, then re-prompt |
| `a` / `A` | Abort | Run cleanup, exit with code 1 |
| `p` / `P` | Pause | Stop the 20-minute timeout; next prompt has no timeout |
| `!cmd` | Shell | Run `cmd`; if it succeeds, skip step; if fails, re-prompt |
| (timeout) | Auto-abort | After 20 minutes of no input, cleanup and exit 1 |

All user actions are logged to the summary log and appear on the dashboard.

---

## Cleanup Model

### conN (cannot be snapshot-reverted -- runner is running on it)

Suites must clean up after themselves. The framework provides:

- **`e2e_add_to_cluster_cleanup "path" [local|remote]`** -- register a cluster
  directory for cleanup on failure. Default is `local` (conN).
- **`e2e_add_to_mirror_cleanup "path" [local|remote]`** -- register a mirror
  for cleanup.
- **`e2e_cleanup_clusters`** / **`e2e_cleanup_mirrors`** -- run registered
  cleanups (called automatically on failure or from interactive prompt).

Cleanup files are persisted at `~/.e2e-harness/logs/<suite>.cleanup` and
`<suite>.mirror-cleanup` so they survive crashes.

**Pre-suite safety net**: Before each suite, `runner.sh` runs
`_pre_suite_cleanup` which processes any leftover cleanup files from crashed
previous suites, kills stale `oc-mirror` processes, and purges caches.

### disN (can be snapshot-reverted or ABA-cleaned)

Two modes controlled by environment variables:

| Mode | Env Variable | How it works |
|------|-------------|--------------|
| **Default** | (none) | `_cleanup_dis_aba`: removes `~/aba`, `~/bin`, caches, quay dirs, CA certs, firewalld test ports. Exercises ABA's own cleanup paths. |
| **Snapshot revert** | `E2E_USE_SNAPSHOT_REVERT=1` | `govc snapshot.revert` disN to `pool-ready`, power on, wait for SSH. Full VMware reset. |

### Post-Suite Integrity Checks

After each suite, `runner.sh` checks for:
- **Orphan VMs** in the pool's vCenter folder (should only contain conN/disN)
- **Leftover containers** on disN (quay, registry, mirror processes)

If either is found, the suite result is overridden to exit code **5** (integrity failure).

---

## Existing Suites

| Suite | What it tests |
|-------|---------------|
| `cluster-ops` | Local registry, SNO install, day2 ops, operator verification, IP conflict detection |
| `airgapped-local-reg` | Bundle creation, Quay/Docker registry, SNO, incremental mirrors, upgrade (OSUS), shutdown/startup, compact with macs.conf |
| `airgapped-existing-reg` | Integration with pre-existing registry, save/load, compact + SNO, ACM operators, NTP day2 |
| `connected-public` | Direct + proxy mode SNO installs with public registries |
| `mirror-sync` | Docker mirror, firewalld, OC_MIRROR_CACHE, save/load roundtrip, bare-metal ISO simulation |
| `create-bundle-to-disk` | Bundle with/without operator filters, all-operators imageset, bare-metal two-step install |
| `network-advanced` | VLAN-based cluster installs (single port + bonding, SNO/compact/standard) |
| `kvm-lifecycle` | KVM platform: SNO creation, VM lifecycle (ls/stop/start/kill), graceful shutdown/startup |
| `vmw-lifecycle` | VMware platform: compact + SNO creation, VM lifecycle, graceful shutdown/startup |
| `cli-validation` | Invalid arguments, bad versions/channels, unknown flags |
| `config-validation` | cluster.conf and mirror.conf validation, ops/op_sets overrides |
| `negative-paths` | Error handling: aba.conf errors, version mismatches, bundle errors, registry recovery |

---

## Dispatcher Internals

The dispatcher in `run.sh` manages suite-to-pool assignment:

1. **Detect existing state**: SSH to each pool, check for running tmux
   sessions and `.rc` result files.
2. **Consume inject queue**: Read `E2E_INJECT_QUEUE` (from `reschedule`)
   and prepend those suites to the front of the work queue (priority).
3. **Build work queue**: From `suites_to_run`, exclude completed and running
   suites.
4. **Dispatch loop** (runs until queue empty and no busy pools):
   - Check busy pools for completion (`.rc` file or tmux gone)
   - Read inject queue for dynamically added suites
   - Read forced dispatch file for one-shot `--force` dispatches
   - Find a free pool, dispatch next suite via tmux on conN
   - Failed suites (non-zero, non-skip) are re-queued up to 2 times
   - Sleep 30s between cycles
5. **Final**: Collect logs from all pools, print summary, notify.

### Key Files (on coordinator)

| File | Purpose |
|------|---------|
| `/tmp/e2e-dispatcher.pid` | Running dispatcher PID |
| `/tmp/e2e-dispatch-state.txt` | Current queue state (for `status`) |
| `/tmp/e2e-inject-queue.txt` | Suite names to inject (from `reschedule`) |
| `/tmp/e2e-forced-dispatch.txt` | One-shot forced dispatches |

### Key Files (on conN)

| File | Purpose |
|------|---------|
| `/tmp/e2e-suite-<name>.rc` | Exit code when suite finishes |
| `/tmp/e2e-suite-<name>.lock` | Prevents concurrent suite execution |
| `/tmp/e2e-last-suites` | Suite name(s) from last run (for `--resume`) |
| `/tmp/e2e-paused-<name>` | Present while suite is paused at prompt |
| `~/.e2e-harness/` | Deployed test harness (lib/, suites/, runner.sh, etc.) |
| `~/.e2e-harness/logs/` | Suite logs, summary, cleanup files |

---

## Troubleshooting

### Suite failed -- how to investigate

```bash
# Check status
./run.sh status

# Attach to the pool to see the interactive prompt (if still waiting)
./run.sh attach con1

# View the dashboard
./run.sh dash

# Read logs directly
ssh steve@con1 "cat ~/.e2e-harness/logs/summary.log"
ssh steve@con1 "tail -100 ~/.e2e-harness/logs/latest.log"
```

### disN is unreachable after a suite crash

```bash
# From conN, check disN connectivity
ssh steve@con1 "ssh dis1 hostname"

# If SSH fails, revert disN to snapshot (from coordinator)
bash setup-infra.sh --pools 1
```

### Stale containers on conN after crash

The pre-suite cleanup handles this automatically. To force it manually:

```bash
ssh steve@con1 "
  podman pod stop quay-pod 2>/dev/null; podman pod rm quay-pod 2>/dev/null
  podman stop -a; podman rm -a
"
```

### Dispatcher thinks a suite is still running

```bash
# Force clear state for a specific suite on a pool
./run.sh run --suite cluster-ops --pool 2 --force
```

### Pool VMs won't start or SSH is broken

```bash
# Verify infrastructure
./run.sh verify --pools 3

# Full rebuild from golden
bash setup-infra.sh --pools 3 --recreate-vms
```

### Resume a partially-completed suite

```bash
# Restart the suite, skipping already-passed tests
./run.sh restart --pool 1 --resume
```

---

## Golden Rules

These rules are enforced by convention and code review. Violating them
leads to flaky tests and hard-to-debug failures.

1. **Tests MUST fail on error** -- never mask underlying issues.

2. **Never use `2>/dev/null` or `|| true`** in test commands. Use
   `e2e_diag` for diagnostic-only commands that are allowed to fail.

3. **When a test fails, check if the fix belongs in ABA code FIRST** --
   never "fix" a test just to make it pass.

4. **Register cleanup early** -- call `e2e_add_to_cluster_cleanup` and
   `e2e_add_to_mirror_cleanup` immediately after creating resources, before
   any step that could fail.

5. **A suite NEVER installs a resource and leaves it for another suite** --
   each suite is self-contained.

6. **Uninstall from the same host that installed** -- if a registry was
   installed on disN, uninstall it from disN.

7. **Never remove tools before operations that need them** -- e.g. don't
   `dnf remove make` before `aba reset`.

8. **Verify cleanup actually worked** -- assert the service is down, the
   directory is gone, the container is removed.

9. **Prefer `aba` commands over raw `make` / scripts** -- eat your own
   dog food.

10. **Never use `(( var++ ))` for arithmetic** -- when `var` is 0,
    `(( 0 ))` returns exit code 1, which crashes under `set -e` or an
    ERR trap. Use `var=$(( var + 1 ))` instead.
