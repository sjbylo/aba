# E2E Test Primer

Quick-start guide for running ABA end-to-end tests with `run.sh`.
For full details see [E2E_TEST_DOCS.md](E2E_TEST_DOCS.md).

All commands run from `test/e2e/`.

---

## Run All Suites

```bash
./run.sh run --all --pools 3
```

Add `--dev` to push your local ABA source code to pool VMs instead of
installing from the internet:

```bash
./run.sh run --all --pools 3 --dev
```

Revert VMs to clean snapshots before starting:

```bash
./run.sh run --all --pools 3 --revert
```

## Run a Single Suite

```bash
./run.sh run --suite cluster-ops --pool 2

# Force re-run (clears previous state)
./run.sh run --suite cluster-ops --pool 2 --force -y
```

## Monitor

```bash
./run.sh status              # Quick status table
./run.sh dash                # Read-only summary dashboard (tmux)
./run.sh live                # Interactive live view (tmux, scrollable)
./run.sh attach con1         # Attach directly to con1's runner session
```

## Deploy Code Changes (without restarting suites)

```bash
./run.sh deploy --pools 3            # Deploy test harness only
./run.sh deploy --dev --pools 3      # Deploy harness + ABA source
./run.sh deploy --force --pools 3    # Hot-deploy even if a suite is running
```

## Stop and Restart

```bash
./run.sh stop --pools 3              # Stop all pools + dispatcher
./run.sh stop --pool 2               # Stop one pool (dispatcher keeps running)
./run.sh restart --pools 3           # Stop, redeploy, re-run last suite
./run.sh restart --pool 1 --resume   # Restart, skip already-passed tests
```

## Queue Management

```bash
./run.sh reschedule --suite kvm-lifecycle   # Inject suite at front of queue
./run.sh list                               # List available suites
```

## VM Power Control

```bash
./run.sh start --pools 3             # Power on all pool VMs
./run.sh start --pool 2              # Power on one pool
./run.sh destroy --pools 3 --clean   # Destroy VMs (cleanup clusters first)
```

## Infrastructure Setup

VMs are created automatically on first `run`. To rebuild manually:

```bash
./run.sh run --all --pools 3 --recreate-vms       # Reclone from golden
./run.sh run --all --pools 3 --recreate-golden     # Rebuild golden + reclone
```

## Common Workflows

**"Tests are failing, I pushed a fix, redeploy and retry"**

```bash
./run.sh deploy --dev --pool 2
./run.sh restart --pool 2 --resume
```

**"Pool 3 is stuck, kill it and requeue the suite"**

```bash
./run.sh stop --pool 3
./run.sh reschedule --suite airgapped-local-reg
```

**"Start fresh on all pools from clean snapshots"**

```bash
./run.sh run --all --pools 3 --revert --dev
```

## Key Options Reference

| Option | Description |
|--------|-------------|
| `--all` | Select all suites |
| `--suite X,Y` | Select specific suite(s) |
| `--pools N` | Number of pools (default: 1) |
| `--pool N` | Target a specific pool |
| `--dev` | Push local source to conN instead of internet install |
| `--resume` | Skip previously-passed tests |
| `--revert` | Revert all VMs to `pool-ready` snapshot before running |
| `--force` | Wipe suite state / hot-deploy |
| `--clean` | Clear checkpoints before running |
| `--dry-run` | Show dispatch plan without executing |
| `-y, --yes` | Auto-accept prompts |
| `-q, --quiet` | CI mode: no interactive prompts |
| `--recreate-vms` | Force reclone all conN/disN from golden |
| `--recreate-golden` | Force rebuild golden VM from template |
| `--os rhel8\|rhel9` | RHEL version for pool VMs |
