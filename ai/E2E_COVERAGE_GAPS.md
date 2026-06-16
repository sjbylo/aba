# E2E Test Coverage Gap Analysis

_Generated: 2026-03-03_

## Fully Tested Code Paths

| Feature | Scripts | Tested In |
|---|---|---|
| `./install` (ABA installation) | `install.sh` | All suites |
| `aba --noask --platform --channel --version` | `aba.sh`, `create-aba-conf.sh` | All suites |
| `aba --dns`, `--ntp`, `--op-sets`, `--ops` | `aba.sh` | All suites |
| `aba -d mirror mirror.conf` | `create-mirror-conf.sh` | Most suites |
| `aba -d mirror verify` | `reg-verify.sh` | connected-public, mirror-sync, airgapped-*, cluster-ops |
| `aba -d mirror install` (Quay) | `reg-install.sh` | mirror-sync, airgapped-local-reg |
| `aba -d mirror install --vendor docker` | `reg-install.sh` | airgapped-local-reg |
| `aba -d mirror uninstall` | `reg-uninstall.sh` | mirror-sync, airgapped-local-reg |
| `aba -d mirror register` | `reg-register.sh` | airgapped-existing-reg |
| `aba -d mirror unregister` | `reg-unregister.sh` | airgapped-existing-reg |
| `aba -d mirror save` | `reg-save.sh` | mirror-sync, airgapped-* |
| `aba -d mirror load` | `reg-load.sh` | mirror-sync, airgapped-* |
| `aba -d mirror sync` | `reg-sync.sh` | mirror-sync |
| `aba -d mirror tar --out -` | `backup.sh` | airgapped-* |
| `aba -d mirror imagesetconf` | `reg-create-imageset-config-*.sh` | airgapped-local-reg, create-bundle |
| `aba -f bundle` (pipe to remote) | `make-bundle.sh` | airgapped-local-reg, create-bundle |
| `aba cluster -n X -t sno/compact/standard` | `create-cluster-conf.sh` | All suites |
| `aba -d X install` (VMware) | `vmw-create.sh`, `monitor-install.sh` | connected-public, mirror-sync, airgapped-*, cluster-ops |
| `aba -d X bootstrap` | `vmw-create.sh` | airgapped-* |
| `aba -d X iso` / `upload` | `generate-image.sh`, `vmw-upload.sh` | network-advanced, cluster-ops |
| `aba -d X run` (oc get co) | `oc-command.sh` | All cluster suites |
| `aba -d X day2` | `day2.sh` | mirror-sync, airgapped-*, cluster-ops |
| `aba -d X day2-ntp` | `day2-ntp.sh` | airgapped-existing-reg |
| `aba -d X day2-osus` | `day2-osus.sh` | airgapped-local-reg |
| `aba -d X delete` | `vmw-delete.sh` | mirror-sync, airgapped-*, cluster-ops |
| `aba -d X shutdown` / `startup` | `vmw-shutdown.sh`, `vmw-startup.sh` | connected-public, airgapped-local-reg |
| `aba -d X ls` | `vmw-list.sh` | airgapped-local-reg |
| `aba -d X login` / `shell` | `oc-login.sh` | airgapped-local-reg |
| `aba -d X ssh --cmd` | `ssh-rendezvous.sh` | network-advanced |
| `aba reset -f` | `reset-gate.sh` | airgapped-existing-reg, create-bundle |
| Bare-metal ISO simulation (3-phase) | `generate-image.sh` | mirror-sync, create-bundle |
| VLAN configs (single-port, bonding) | `create-cluster-conf.sh` | network-advanced |
| Proxy mode install | `aba.sh` | connected-public |
| Incremental mirror (add images/operators) | `reg-save.sh`, `reg-load.sh` | airgapped-local-reg |
| Cluster upgrade via OSUS | `day2-osus.sh` | airgapped-local-reg |

## Script-Level Gaps (never or barely tested)

| Feature | Scripts | Notes |
|---|---|---|
| `aba tar` / `aba tarrepo` | `backup.sh` | Backup entire ABA repo. Never tested. |
| `aba -d X rescue` | `vmw-rescue.sh` | Re-upload ISO and reboot failed node. Never tested. |
| `aba -d X kill` | `vmw-kill.sh` | Force-kill VMs. Never tested. |
| `aba -d X stop` | `vmw-stop.sh` | Stop individual VMs. Never tested. |
| `aba -d X start` | `vmw-start.sh` | Start individual VMs. Never tested. |
| `aba -d X mon` | `monitor-install.sh` | Standalone monitor. Never tested standalone. |
| `aba -d X info` | `oc-login.sh` | Show cluster info. Never tested. |
| `aba -d X refresh` | `generate-image.sh` | Re-gen ISO + re-upload. Partially in network-advanced. |
| `aba -d cli download` | `cli-download-all.sh` | Only tested as side-effect. |
| `aba -d cli install` | `cli-install-all.sh` | Only tested as side-effect. |
| `aba -d mirror clean` | Makefile clean | Only as prep, not independently verified. |
| `aba clean` | top-level clean | Never tested. |
| Named mirror dirs | `setup-mirror.sh` | Custom names (e.g. `mymirror/`) not E2E tested. |
| Multi-cluster coexistence | various | 2+ clusters from same mirror not tested. |
| Testy user full workflow | various | Only partial (reg_ssh_user). |
| `--ask` interactive mode | `aba.sh` | All tests use `ask=false`. |

## Negative / Error-Handling Path Gaps (inside scripts)

_Audited: 2026-03-03. Scripts ranked by risk (severity x untested probability x complexity)._

### 1. `aba.sh` (~215 branches, ~75 error paths) -- HIGHEST RISK

The CLI entry point. Every user interaction flows through this script.
All error paths were untested until `suite-cli-validation.sh` was added.

| Error Path | Line(s) | Now Tested? |
|---|---|---|
| Bad `--version` format | 367 | YES (cli-validation) |
| Missing `--version` arg | 341 | YES (cli-validation) |
| Version not in channel | 364 | YES (cli-validation) |
| Invalid `--channel` | 332-333 | YES (cli-validation) |
| Missing `--channel` arg | 323 | YES (cli-validation) |
| Missing `--dir` value | 76 | YES (cli-validation) |
| `--dir` to non-existent path | 77 | YES (cli-validation) |
| `--dir` to a file | 78 | YES (cli-validation) |
| Invalid `--platform` | 583 | YES (cli-validation) |
| Invalid `--vendor` | 415 | YES (cli-validation) |
| Invalid `--type` | 779-780 | YES (cli-validation) |
| Unknown flag | 893-701 | YES (cli-validation) |
| Bad `--reg-port` | 421-422 | YES (cli-validation) |
| Bad `--api-vip` IP | 524-528 | YES (cli-validation) |
| Bad `--machine-network` CIDR | 471-472 | YES (cli-validation) |
| Bad `--dns` IP | 481-487 | YES (cli-validation) |
| `--out` to existing tar | 314 | YES (cli-validation) |
| Mac OS unsupported | 37 | No (infeasible in E2E) |
| Sudo/root check | 53-54 | No (test user has sudo) |
| `--out` parent dir missing | 313 | No (low risk) |
| Permission denied on `cd --dir` | 82-86 | No (hard to set up safely) |
| Interactive mode paths | 1003-1451 | No (all tests use `--noask`) |

### 2. `create-install-config.sh` (~20 branches)

Generates the core OpenShift install-config.yaml. Wrong config = failed cluster.

| Error Path | Line(s) | Now Tested? |
|---|---|---|
| Missing pull secret entirely | 159-170 | No (would break all suites if triggered) |
| Invalid `int_connection` | 91-95 | No (aba.sh validates first) |
| Missing rootCA.pem for mirror | 126-143 | No (always present in test flows) |
| Proxy vars not set in proxy mode | 82-89 | No (connected-public covers proxy happy path) |

### 3. `reg-uninstall.sh` (20 branches, 8 error paths)

Destructive operation. Wrong branch = data loss or orphaned registry.

| Error Path | Line(s) | Now Tested? |
|---|---|---|
| Uninstall when state=existing (abort) | 23-29 | YES (airgapped-existing-reg) |
| User declined uninstall (remote) | 85-86 | No (tests use `-y`) |
| User declined uninstall (local) | 98-99 | No (tests use `-y`) |
| No registry detected (graceful exit) | 101-104 | No (low risk -- just info msg) |
| Uninstall command failure | 84, 97 | No (hard to trigger safely) |

### 4. `reg-save.sh` / `reg-load.sh` / `reg-sync.sh` (~65 branches combined)

Hours-long mirror operations that fail silently on bad state.

| Error Path | Script | Line(s) | Now Tested? |
|---|---|---|---|
| No internet | reg-save.sh | 17-21 | No (infeasible -- test needs internet) |
| No internet | reg-sync.sh | 57-61 | No (same) |
| `oc-mirror` not available | reg-save/load/sync | various | No (always installed) |
| Low disk (<20GB) | reg-save.sh | 67-71 | No (hard to simulate) |
| Missing pull secret | reg-sync.sh | 48-52 | YES (mirror-sync) |
| Registry unreachable | reg-sync.sh | 79-84 | YES (airgapped-existing-reg, "sync to unknown host") |
| Missing `save/` dir | reg-load.sh | 80-82 | YES (airgapped-local-reg) |
| All retries exhausted | reg-save/load/sync | various | No (would need unreliable registry) |

### 5. `vmw-create.sh` (18 branches, 7 error/edge paths)

VM creation with subtle defaults (memory, nested HV, MAC check).

| Error Path | Line(s) | Now Tested? |
|---|---|---|
| Missing vmware.conf | 17-20 | YES (create-bundle-to-disk) |
| cluster-config.sh failure | 25 | No (always works with valid config) |
| MAC check failure | 45 | No (hard to trigger reliably) |
| Low master memory workaround | 71 | No (implicit -- tested with default mem) |
| aba.conf validation failure | 52 | No (always valid in tests) |

## Methodology for Negative Path Audit

To identify untested conditional branches inside scripts:
1. Extract all `if/else/elif`, `||`, `&&`, `case` branches from each script
2. Identify which branches are "error/edge" paths (e.g. missing file, wrong state, bad input)
3. Cross-reference with E2E suites and `e2e_run_must_fail` calls
4. Flag branches that are never exercised by any test
