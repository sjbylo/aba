# E2E Framework Flag Testing Plan

Goal: Systematically test all E2E suites with different flag combinations to verify
the framework handles --user, --os, --vmware-conf, --revert, --recreate-vms, and
--recreate-golden correctly.

## Flag Matrix

| Flag              | Values                                         |
|-------------------|-------------------------------------------------|
| --user            | steve, root                                     |
| --os              | rhel8, rhel9                                    |
| --vmware-conf     | ~/.vmware.conf (VC), ~/.vmware.conf.esxi (ESXi) |
| --revert          | yes / no                                        |
| --recreate-vms    | yes / no                                        |
| --recreate-golden | yes / no (required first time for rhel9)        |

## Phases

### Phase 1: Quick suites, flag acceptance (est. 1-2h)
Verify all flag combinations are accepted and don't crash.
Suites: cli-validation, config-validation, negative-paths

| Run | Pool | Suite             | --user | --os  | --vmware-conf | Extra flags        |
|-----|------|-------------------|--------|-------|---------------|--------------------|
|  1  |  3   | config-validation | steve  | rhel8 | esxi          | --revert           |
|  2  |  *   | cli-validation    | root   | rhel8 | default       | --revert           |
|  3  |  *   | negative-paths    | steve  | rhel8 | esxi          |                    |
|  4  |  *   | cli-validation    | root   | rhel8 | esxi          | --revert           |
|  5  |  *   | config-validation | root   | rhel8 | default       |                    |
|  6  |  *   | negative-paths    | root   | rhel8 | esxi          | --revert           |

### Phase 2: --recreate-vms (est. 1-2h)
Verify --recreate-vms properly reclones pool VMs from golden.

| Run | Pool | Suite             | --user | --os  | --vmware-conf | Extra flags        |
|-----|------|-------------------|--------|-------|---------------|--------------------|
|  7  |  *   | cli-validation    | steve  | rhel8 | default       | --recreate-vms     |
|  8  |  *   | config-validation | root   | rhel8 | esxi          | --recreate-vms     |

### Phase 3: --recreate-golden + --os rhel9 (est. 2-4h)
Build rhel9 golden VM and verify suites work on RHEL 9.

| Run | Pool | Suite             | --user | --os  | --vmware-conf | Extra flags                       |
|-----|------|-------------------|--------|-------|---------------|-----------------------------------|
|  9  |  *   | cli-validation    | steve  | rhel9 | default       | --recreate-golden --recreate-vms  |
| 10  |  *   | config-validation | root   | rhel9 | default       |                                   |
| 11  |  *   | negative-paths    | steve  | rhel9 | esxi          |                                   |

### Phase 4: Medium suites with flags (est. 2-4h)
Verify substantive suites with different flag combos.

| Run | Pool | Suite                 | --user | --os  | --vmware-conf | Extra flags |
|-----|------|-----------------------|--------|-------|---------------|-------------|
| 12  |  *   | create-bundle-to-disk | steve  | rhel8 | default       |             |
| 13  |  *   | create-bundle-to-disk | root   | rhel8 | esxi          | --revert    |
| 14  |  *   | connected-public      | steve  | rhel8 | esxi          |             |
| 15  |  *   | connected-public      | root   | rhel8 | default       | --revert    |

### Phase 5: Long suites (est. 4-8h)
Full integration suites covering mirror, airgapped, cluster operations.

| Run | Pool | Suite                  | --user | --os  | --vmware-conf | Extra flags |
|-----|------|------------------------|--------|-------|---------------|-------------|
| 16  |  *   | mirror-sync            | steve  | rhel8 | default       |             |
| 17  |  *   | mirror-sync            | root   | rhel8 | esxi          | --revert    |
| 18  |  *   | airgapped-local-reg    | steve  | rhel8 | default       |             |
| 19  |  *   | airgapped-existing-reg | root   | rhel8 | esxi          |             |
| 20  |  *   | cluster-ops            | steve  | rhel8 | default       |             |
| 21  |  *   | vmw-lifecycle          | root   | rhel8 | default       |             |
| 22  |  *   | network-advanced       | steve  | rhel8 | esxi          |             |

### Phase 6: Long suites on rhel9 (est. 4-8h, if Phase 3 passed)

| Run | Pool | Suite                  | --user | --os  | --vmware-conf | Extra flags |
|-----|------|------------------------|--------|-------|---------------|-------------|
| 23  |  *   | mirror-sync            | root   | rhel9 | default       |             |
| 24  |  *   | airgapped-local-reg    | steve  | rhel9 | default       |             |
| 25  |  *   | create-bundle-to-disk  | root   | rhel9 | esxi          |             |

## Execution Rules

1. Check pool status every 5 minutes
2. When a pool becomes free, pick the next unstarted run from the plan
3. Use `--force -y` for all dispatches
4. Always use `--pools 4` to avoid clobbering the saved pools count
5. Record PASS/FAIL result for each run
6. If a run FAILs, note the failure and move on -- don't block other runs
7. Keep all 4 pools busy at all times

## Results Tracker

| Run | Suite | Flags | Pool | Result | Duration | Notes |
|-----|-------|-------|------|--------|----------|-------|
| 1 | config-validation | steve / rhel8 / esxi / --revert | 3 | PASSED 5/5 | 1m 24s | |
| 2 | cli-validation | root / rhel8 / default / --revert | 2 | PASSED 9/9 | 1m 3s | |
| 3 | negative-paths | steve / rhel8 / esxi | 3 | PASSED 8/8 | 6m 36s | |
| 4 | cli-validation | root / rhel8 / esxi / --revert | 2 | PASSED 9/9 | 1m 2s | |
| 5 | config-validation | root / rhel8 / default | 2 | PASSED 5/5 | 1m 29s | |
| 6 | negative-paths | root / rhel8 / esxi / --revert | 2 | PASSED | | (result pending) |
| 7 | cli-validation | steve / rhel8 / --recreate-vms | 1 | FAILED | | VM clone failed (setup-infra) |
| 8 | config-validation | root / rhel8 / esxi / --recreate-vms | 3 | FAILED | | VM clone failed (setup-infra) |
| 12 | create-bundle-to-disk | steve / rhel8 / default | 1 | PASSED 11/11 | 56m 53s | |
| 13 | create-bundle-to-disk | root / rhel8 / esxi | 2 | PASSED | | (reverted before log check) |
| 14 | connected-public | steve / rhel8 / esxi | 3 | RUNNING | | |
| 15 | connected-public | root / rhel8 / default | 4 | RUNNING | | |
| 16 | mirror-sync | steve / rhel8 / default | 1 | RUNNING | | Phase 5 |
