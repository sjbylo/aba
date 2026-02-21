# ABA E2E Test Framework

End-to-end tests that validate ABA against real VMware infrastructure and OpenShift clusters.

## Prerequisites

| Requirement | Details |
|---|---|
| VMware vCenter | Access to ESXi/vCenter with `govc` CLI |
| `~/.vmware.conf` | govc configuration (or set `VMWARE_CONF` in `config.env`) |
| `~/.pull-secret.json` | Red Hat pull secret for mirror and bundle tests |
| Template VMs | `aba-e2e-template-rhel8` (and optionally rhel9/rhel10) with snapshot `aba-test` |
| Network | DHCP + DNS for `*.example.com`, VLAN-capable switch for network-advanced suite |
| SSH | Key-based access to bastion hosts |

## Quick Start

```bash
# Provision pool(s) from scratch (golden VM + clones)
test/e2e/run.sh --create-pools 1

# Force-rebuild the golden VM even if the snapshot is fresh
test/e2e/run.sh --create-pools 1 --rebuild-golden

# Run a single suite (recommended to start here)
test/e2e/run.sh --suite cluster-ops

# Run all suites sequentially with interactive retry on failure
test/e2e/go.sh

# Run all suites
test/e2e/run.sh --all

# Resume from last checkpoint after a failure
test/e2e/run.sh --suite cluster-ops --resume

# Clean state files and start fresh
test/e2e/run.sh --suite cluster-ops --clean

# Dry run (show what would execute)
test/e2e/run.sh --all --dry-run
```

## Golden VM Provisioning

Pool creation uses a **golden VM** pattern to avoid repeating expensive setup
steps (SSH keys, firewall, NTP, `dnf update`, test user, etc.) for every clone.

### How it works

```
Template VM                Golden VM                   Pool VMs
(aba-e2e-template-rhel8)   (aba-e2e-golden-rhel8)      (con1, dis1, con2, ...)
        |                         |                          |
        |   Phase 0: clone +      |                          |
        |   full setup + snapshot  |                          |
        +------------------------>|                          |
                                  |  Phase 1: linked-clone   |
                                  |  from golden snapshot    |
                                  +------------------------->|
                                                             |
                                              Phase 2: lightweight
                                              per-pool config only
                                              (network, dnsmasq, aba)
```

**Phase 0 -- `prepare_golden_vm`**: Clones the raw template, applies all common
configuration (SSH keys, proxy, firewall, NTP/chrony, `dnf update`, podman
cleanup, test user `testy`, `ABA_TESTING=1`), verifies the result, powers off,
and creates a `golden-ready` snapshot. A timestamp is written to
`~/.cache/aba-e2e/<name>.stamp` so the golden VM can be reused across runs.

**Phase 1 -- Clone**: Each pool's `conN`/`disN` VMs are cloned in parallel from
the golden snapshot. This takes ~15 seconds per clone instead of minutes.

**Phase 2 -- Per-pool config**: Only lightweight, pool-specific steps run on
each clone: network setup (`_vm_setup_network`), `dnsmasq`, `vmware.conf`,
and ABA installation. `disN` bastions additionally have RPMs removed, proxy
stripped, and internet disconnected.

### Staleness and refresh

The golden snapshot is reused if it is less than `GOLDEN_MAX_AGE_HOURS` old
(default: 24h). When stale, the golden VM is reverted to its snapshot, booted,
updated (`dnf clean all && dnf update`), re-verified, and re-snapshotted.

Use `--rebuild-golden` to force a full teardown and rebuild from the raw
template regardless of age.

### Error handling (`set -e` in bash conditionals)

`prepare_golden_vm` uses `set -e` for strict error handling. A subtle bash
quirk means `set -e` is suppressed inside subshells that are part of
conditional constructs (`if cmd`, `cmd || handler`, `cmd && next`). To work
around this, `create_pools` runs the golden VM subshell **outside** any
conditional context and captures `$?` on the next line:

```bash
( prepare_golden_vm ... ) >> "$log" 2>&1
local rc=$?
if [ "$rc" -ne 0 ]; then ...
```

## Configuration

### `config.env`

Baseline defaults for all test runs. Override precedence: CLI flags > pool overrides > `config.env`.

Key parameters:
- `TEST_CHANNEL` / `OCP_VERSION` -- OpenShift channel and version
- `INT_BASTION_RHEL_VER` -- RHEL version for internal bastions
- `CON_SSH_USER` -- SSH user for connected bastion (con1/con2)
- `DIS_SSH_USER` -- SSH user for disconnected bastion (dis1/dis2)
- `VMWARE_CONF` / `VC_FOLDER` / `VM_DATASTORE` -- VMware settings
- `VM_CLONE_MACS` -- Per-clone MAC addresses (tied to DHCP reservations)
- `VM_CLONE_VLAN_IPS` -- Static VLAN IPs for bastion clones
- `GOLDEN_MAX_AGE_HOURS` -- Hours before the golden snapshot is refreshed (default: 24)
- `POOL_*` arrays -- Per-pool cluster IPs, domains, VIPs

### `pools.conf`

Defines independent test environments for parallel execution.

```
# Format:
#   POOL_NAME  CONNECTED_HOST  INTERNAL_HOST  INTERNAL_VM_NAME  [KEY=VAL ...]

pool1  con1  dis1  aba-e2e-template-rhel8   INT_BASTION_RHEL_VER=rhel8  POOL_NUM=1
```

`POOL_NUM` drives per-pool uniqueness via config.env arrays:
- Pool 1: `p1.example.com`, node=`10.0.2.12`, API=`10.0.2.13`, apps=`10.0.2.14`
- Pool 2: `p2.example.com`, node=`10.0.2.22`, API=`10.0.2.23`, apps=`10.0.2.24`
- Pool 3/4: same pattern at `.32`/`.42`

## IP/Domain Allocation

### E2E Pools (10.0.2.x)

Each pool gets a "decade" within `10.0.2.0/24`:

| Pool | Domain | Node IP | API VIP | Apps VIP | Con Bastion | Dis Bastion |
|------|--------|---------|---------|----------|-------------|-------------|
| 1 | p1.example.com | 10.0.2.12 | 10.0.2.13 | 10.0.2.14 | con1 (.10) | dis1 (.11) |
| 2 | p2.example.com | 10.0.2.22 | 10.0.2.23 | 10.0.2.24 | con2 (.20) | dis2 (.21) |
| 3 | p3.example.com | 10.0.2.32 | 10.0.2.33 | 10.0.2.34 | con3 (.30) | dis3 (.31) |
| 4 | p4.example.com | 10.0.2.42 | 10.0.2.43 | 10.0.2.44 | con4 (.40) | dis4 (.41) |

### VLAN IPs (10.10.20.x)

Bastion VLAN interfaces (ens224.10, static):
- con1=10.10.20.1, dis1=10.10.20.2, con2=10.10.20.3, dis2=10.10.20.4, ...

VLAN cluster nodes (for network-advanced suite):
- Pool 1: 10.10.20.201, Pool 2: 10.10.20.202, ...

### Legacy Tests (10.0.1.x) -- No Overlap

The legacy `test/test[12345]*.sh` scripts use `10.0.1.x` (SNO=.201, compact=.71, standard=.81) and `registry.example.com`. These do **not** overlap with E2E pool IPs (`10.0.2.x`) or domains (`pN.example.com`).

## Test Suites

### Recommended Run Order

| # | Suite | Purpose | Dependencies |
|---|-------|---------|--------------|
| 1 | `create-bundle-to-disk` | Bundle creation (no VMs) | Internet, pull-secret |
| 2 | `clone-and-check` | Full pool setup (conN + disN) | govc, VMware |
| 3 | `connected-public` | Public registry SNO | VMware (no internal bastion) |
| 4 | `cluster-ops` | ABI config validation + SNO install | clone-and-check must run first |
| 5 | `mirror-sync` | Mirror sync/save/load + firewalld | clone-and-check must run first |
| 6 | `airgapped-existing-reg` | Air-gap with existing registry | clone-and-check must run first |
| 7 | `airgapped-local-reg` | Full air-gap (longest) | clone-and-check must run first |
| 8 | `network-advanced` | VLAN and bonding | clone-and-check first, VLAN infra |

### Suite Details

- **create-bundle-to-disk**: Creates light and full bundles, verifies contents. No VMs needed.
- **clone-and-check**: Creates conN+disN bastion pair, configures networking/firewall/dnsmasq. Required by most other suites.
- **connected-public**: SNO install using public registry (no mirror). Tests direct + proxy modes.
- **cluster-ops**: ABI config generation, YAML diff against known-good examples, SNO cluster install/verify.
- **mirror-sync**: Sync to remote registry with firewalld, save/load roundtrip, testy user re-sync, bare-metal ISO.
- **airgapped-local-reg**: Full air-gap workflow: bundle, transfer, install Quay+Docker, upgrade, ACM.
- **airgapped-existing-reg**: Air-gap with pre-existing registry. Tests existing-registry detection.
- **network-advanced**: VLAN-based and bonded cluster installs. Needs VLAN-capable switch.

## Checkpoints and Resume

Each suite writes progress to `.state` files (e.g., `clone-and-check.state`). Use `--resume` to skip already-passed tests after a failure. Use `--clean` to reset state and start fresh.

## Framework policies

### Pools always get new work

Pools must always get new work. If a test or suite fails, we need to find out **why** and what is needed so tests pass again. For example, some state may need clearing after a suite finishes or fails. We must identify that and, if needed, reset the pool (e.g. clear data in `/home/steve` or `/root`, or clear and remove failed mirrors) so it works again. Do not exclude a pool from further work after a failure; fix the cause and add any required cleanup so the next suite can run.

### Pool reset before each suite (snapshot-based)

The parallel dispatcher **resets** each pool immediately before dispatching a suite by reverting the pool's conN and disN VMs to the `pool-ready` VMware snapshot. This snapshot is created by `clone-and-check` **only after all validations pass**, guaranteeing that every suite starts from a known-good, fully configured state.

**How it works:**

1. `clone-and-check` runs all configuration and validation steps on the pool's VMs.
2. Only if every validation passes, `govc snapshot.create pool-ready` is called on both conN and disN.
3. Before each suite dispatch, the parallel dispatcher runs `govc snapshot.revert pool-ready` on both VMs, powers them on, and waits for SSH.

If the `pool-ready` snapshot does not exist (e.g. clone-and-check has not run or failed), the dispatcher prints an error and skips the pool.

Once all suites are passing reliably, we will try runs **without** pool reset and then decide the long-term policy. To disable reset, set `E2E_RESET_POOL_BEFORE_SUITE=0`.

### Pause on failure (while polishing)

While the test framework is being polished, the parallel dispatcher **pauses** on the first suite failure: it stops assigning new work, lets running jobs finish, then exits with a message so you can debug and add cleanup code. Set `E2E_PAUSE_ON_FAILURE=0` (or use `--ci`) to run to completion without pausing. See [Parallel Execution](#parallel-execution) below.

## Parallel Execution

Uncomment additional pools in `pools.conf`, then:

```bash
test/e2e/run.sh --parallel --all --pools pools.conf
```

Each pool runs suites independently on its own bastion pair. By default, the first suite failure pauses the run so you can debug and add pool cleanup; re-run when ready.

## Writing a New Suite

1. Create `suites/suite-<name>.sh`
2. Source the framework and helpers:
   ```bash
   source "$_SUITE_DIR/../lib/framework.sh"
   source "$_SUITE_DIR/../lib/config-helpers.sh"
   ```
3. Structure:
   ```bash
   e2e_setup
   plan_tests "Test 1" "Test 2" "Test 3"
   suite_begin "<name>"

   test_begin "Test 1"
   e2e_run "Description" "command"
   test_end 0

   # ... more tests ...

   suite_end
   ```
4. Key functions:
   - `e2e_run "desc" "cmd"` -- run a command, log it, fail on error
   - `e2e_run_remote "desc" "cmd"` -- run on internal bastion via SSH
   - `e2e_run_must_fail "desc" "cmd"` -- expect failure
   - `pool_domain`, `pool_node_ip`, `pool_api_vip`, etc. -- pool-aware helpers
   - `assert_file_exists`, `assert_contains`, etc. -- assertions
   - `require_govc`, `require_ssh`, etc. -- guards

## Logs

Suite output is written to stdout/stderr. Use `--notify` with a notification command to get alerts on completion/failure.

Pool provisioning logs:
- `logs/golden-<rhel_ver>.log` -- Golden VM build/refresh output
- `logs/create-pool<N>.log` -- Per-pool clone + configuration output
