# E2E Test Audit: Old vs New Coverage

Compares old tests (`test/test[12345]*`) with new E2E suites (`test/e2e/suites/`).

## Mapping: Old to New

| Old Test | Primary New Suite(s) | Coverage |
|----------|---------------------|----------|
| test1 (sync, save/load, bare-metal) | suite-mirror-sync + suite-cluster-ops | ~80% |
| test2 (airgapped existing reg, VLAN/bond, ACM) | suite-airgapped-existing-reg + suite-network-advanced | ~75% |
| test3 (public/direct/proxy install) | suite-connected-public | ~95% |
| test4 (bundle to disk) | suite-create-bundle-to-disk | ~95% |
| test5 (airgapped local reg, mesh, upgrade, BYO MACs) | suite-airgapped-local-reg | ~85% |

## MISSING Coverage (Important)

### 1. RPM removal / clean-system bootstrap
Every old test starts with `sudo dnf remove git hostname make jq ...` to simulate a
minimal RHEL where ABA must install its own dependencies. No new suite tests this.
This verifies ABA's `./install` can bootstrap on a bare system.

### 2. ABA script self-update test (test1 lines 80-85)
Old test modifies `ABA_BUILD` timestamp in `scripts/aba.sh`, runs `aba -h`, and verifies
the installed binary is updated. Not in any new suite.

### 3. Registry probing / negative install tests (test2 lines 176-179)
Old test2 verifies these MUST FAIL:
- `aba -d mirror -H unknown.example.com install` (unknown host)
- `aba -d mirror -H $existing_host install` (already exists)
- `aba -d mirror -H $local_hostname install` (local host detection)

Not in any new suite. (suite-negative-paths tests different error paths.)

### 4. Mirror reset + run_once verification (test1 lines 278-284)
Old test verifies:
- `~/.aba/runner/mirror:reg:install` exists before reset
- `aba --dir mirror reset --force` clears it
- `mirror-registry` binary is removed
- Re-extracting binary after reset works

Not in any new suite.

### 5. Machine network CIDR variations (test1 lines 353-360)
Old test creates SNO clusters with both small CIDR (10.0.1.200/30) and large CIDR
(10.0.0.0/20) to verify ABA handles edge-case network configs. Not in any new suite.

### 6. Standard cluster install in airgapped flow (test5 build_and_test_cluster)
Old test5 builds and installs a full 6-node standard cluster from the airgapped bundle,
including bootstrap monitoring, worker restart if workers don't come online, full cluster
operator wait, shutdown/startup lifecycle. New suite-airgapped-local-reg only installs
SNO in this flow.

### 7. `aba -d cli download-all` (test1 lines 399-402)
Verifies that `download-all` downloads govc even in bare-metal mode. Not in any new suite.

### 8. `aba clean` command (test1/test2 uses throughout)
Old tests use `aba --dir sno clean` to reset cluster state (preserves cluster.conf).
New suites generally use `rm -rf` instead. The clean command itself is untested.

### 9. Full ACM operator deployment + Multiclusterhub (test2 lines 596-607)
Old test2 goes beyond verifying packagemanifests -- it actually:
- Installs ACM Subscription (`oc apply -f acm-subs.yaml`)
- Installs Multiclusterhub (`oc apply -f acm-mch.yaml`)
- Waits for MCH status to be Running (up to 8 min)

New suite-airgapped-existing-reg only checks `oc get packagemanifests | grep
advanced-cluster-management`. The actual ACM/MCH install is not tested.

### 10. Quay-to-Docker swap sequence (test5 lines 218-222)
Old test5 explicitly: install Quay, uninstall Quay, install Docker, verify, load.
New suite-airgapped-local-reg does a similar swap but the exact
install/uninstall/reinstall sequence should be verified.

## NEW Coverage (Not in Old Tests)

| New Suite | New Coverage |
|-----------|-------------|
| suite-config-validation | cluster.conf and mirror.conf validation with e2e_run_must_fail |
| suite-negative-paths | aba.conf validation, version mismatch, bundle/registry/cluster error paths |
| suite-cli-validation | CLI input checks: bad version/channel, bad --dir, invalid platform/vendor/type, unknown flags |
| suite-cluster-ops | ABI config diff against known-good examples (standalone, with operator sync) |
| suite-connected-public | no_proxy field verification in install-config.yaml |
| suite-mirror-sync | reg_detect_existing() regression test (stale credentials detection) |

## Priority of Missing Items

**High priority** (core user workflows):
1. RPM clean-start bootstrap
2. Standard cluster install from airgapped flow
3. Mirror reset + run_once verification
4. Registry probing negative tests

**Medium priority** (important features):
5. ABA script self-update
6. Full ACM/MCH deployment (not just packagemanifests check)
7. Machine network CIDR variations
8. `aba clean` command

**Low priority** (nice to have):
9. `aba -d cli download-all`
10. Quay-to-Docker exact swap sequence verification
