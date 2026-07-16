## [Unreleased](https://github.com/sjbylo/aba/compare/v1.1.4...HEAD)

Primed bundles, TUI upgrade picker, catalog prefetch, RHEL 10 support, and improved UX

### New Features

- **`aba bundle --primed`** — Bundle pre-configured cluster directories (with pre-built `install-config.yaml` and `agent-config.yaml`) alongside the mirror data. On the disconnected side, Make skips regeneration for primed clusters (`.primed` marker), while cluster.conf-only directories still go through normal config generation. Supports mixed bundles with both pre-built and unconfigured clusters.
- **TUI upgrade path picker** — Upgrade menu now queries available versions from the mirror registry and validates them against the Cincinnati upgrade graph, showing only safe upgrade targets.
- **Catalog prefetch for next minor** — Background pre-download of operator catalogs for the next OCP minor version (e.g. if on 4.21, prefetch 4.22 catalogs), prioritizing the `redhat` catalog.
- **`aba transfer-info`** — New command to show transfer tar contents, metadata, and cluster directory summary.
- **Suggest `aba unstick` on install failure** — When cluster install fails with stuck pods, the error message now suggests running `aba unstick` as a recovery step.
- **Container image workflow** — Containerfile and documentation for running ABA inside a container for disconnected deployments.

### Improvements

- **RHEL 10 support** — RHEL 10 and CentOS Stream 10 added as supported platforms in documentation and prerequisites.
- **Clarified sudo requirements** — Documentation now emphasizes that ABA runs as a normal user with `sudo` for system operations; root is optional, not required.
- **Context-aware next steps** — `aba load`, `aba save`, and `aba sync` now show condensed, context-appropriate hints (e.g. suggests `day2` + `upgrade` for upgrade loads, or `aba cluster` for new installs) with consistent coloring.
- **TUI: smart DISCO menu focus** — After a state-changing action (e.g. `load`), the menu cursor automatically moves to the logical next step (e.g. "Install cluster").
- **TUI: day2 offer after load** — TUI offers to run `aba day2` immediately after loading images, since it's always the next step.
- **TUI: improved upgrade UX** — Clearer wording, cancel hints, and better dialog flow in the upgrade workflow.
- **Agent wait timeout increased to 5 min** — Accommodates slower VM boot times across all platforms.
- **Skip agent wait on install retry** — When `aba install` is retried after the agent was already detected, the agent wait is skipped.
- **`aba unstick` refactored** — Single-pass pod detection with generic status matching replaces a hardcoded status list.
- **`try_cmd()` retry consolidation** — Common retry logic extracted into a shared `try_cmd()` function, reducing duplication across scripts.
- **Candidate-exclusive version discovery** — `aba ocp-versions` now shows candidate channel versions that are not yet in the fast channel.
- **README: abatui mentioned alongside aba** — Workflow entry points now mention `abatui` as an alternative.
- **README: bare-metal example** — Comprehensive bare-metal configuration example with network diagram, DNS records, and pre-flight checklist.
- **`ocp_version` semantic separation** — `ocp_version` in `aba.conf` is now strictly "user intent" (what to install), cleanly separated from `ocp_version` in `state.sh` (what the mirror currently holds).

### Bug Fixes

- **Fix ODF operator set missing `ocs-tls-profiles`** — Added `ocs-tls-profiles` to `operator-set-odf`, fixing ODF installation failures on recent OCP versions.
- **Fix catalog extraction retry** — Transient Podman "no such container" errors during catalog extraction now trigger automatic retry instead of aborting.
- **Fix Docker registry image download path** — Corrected source path in `download-docker-reg-image.sh`.
- **Fix `--primed` bundle symlink restoration** — EXIT trap now restores the exact original symlink targets (e.g. `mirror/mirror.conf` vs `../vmware.conf`) instead of using a generic `../$name` pattern.
- **Fix `--primed` mirror.conf exclusion** — Resolved `mirror.conf` copies in primed cluster directories are no longer excluded from the tarball when a local registry is installed.
- **Fix `.primed` guard on install-config.yaml** — Removed overly strict `.primed` guard that prevented `install-config.yaml` regeneration when cluster configs changed.
- **Fix `aba save` color output** — Removed stale `PLAIN_OUTPUT=1` export in `reg-save.sh` that suppressed all color output.

---

## [1.1.4](https://github.com/sjbylo/aba/releases/tag/v1.1.4) - 2026-07-11

Disconnected upgrade workflow, mirror state tracking, bare-metal write-usb, and 30+ bug fixes


### New Features

- **Disconnected upgrade transfer bundle** — `aba save` now creates an `aba-transfer.tar` bundle containing the ImageSet Config, digest-pinned ISC, CLI binaries, and metadata. On the disconnected host, `aba load` unpacks the bundle automatically. Transfer is now simply `cp mirror/data/*.tar` — no manual ISC or CLI copying needed.
- **Mirror state tracking** — Mirror operational state (`ocp_version`, `last_action`, `last_action_at`) is now tracked in per-mirror `state.sh` files. Previously, `reg-load.sh`/`reg-sync.sh` wrote the loaded version back to `aba.conf`, overwriting user intent with operational fact. State is now cleanly separated from configuration.
- **`aba write-usb`** — New command for bare-metal installs that displays ISO details (path, size, SHA256), lists block devices with mount point warnings, refuses system disks, and shows the exact `dd` command before executing. Improved bare-metal guidance throughout the install flow.
- **`aba unstick`** — New command to bounce not-ready pods during stuck cluster installs. Detects pods in error states (`CrashLoopBackOff`, `ImagePullBackOff`, `ContainerStatusUnknown`, `Init:*` prefixed states) and deletes them to trigger rescheduling.
- **KVM connection pre-flight** — TUI connection test now verifies KVM storage pool exists and is writable (with free space shown) and that the network bridge exists (with link state).
- **`ask()` auto-answer modes** — `--auto-yes` and `--auto-no` flags decouple the interactive default from the non-interactive (automation) response, allowing safe defaults for humans with automatic proceed for scripting.
- **`--lite` alias** — `aba bundle --lite` accepted as synonym for `--light`.

### Improvements

- **Upgrade `--force` tolerates warnings** — `aba upgrade --force` now adds `--allow-upgrade-with-warnings` to bypass transiently degraded operators, matching the intent of forcing an upgrade. Prominent warnings added about `--force` not being for production.
- **Upgrade `--force` bypasses admin ack** — `--force` now skips the interactive `AdminAckRequired` prompt for cross-minor upgrades, enabling fully automated upgrade workflows.
- **Rename `--target-version` to `--upgrade-to`** — The CLI flag and config variable (`ocp_version_target` → `ocp_upgrade_to`) are renamed to unambiguously indicate upgrade intent. Old names are not accepted (clean break).
- **`aba-transfer.tar` always bundles ISC** — The transfer bundle is now created for all save operations (not just upgrades), ensuring incremental saves (e.g. `additionalImages`) transfer the correct ISC to the disconnected host.
- **TUI: Prepare Upgrade (beta) label** — The upgrade workflow menu item is labeled as beta to set expectations.
- **TUI: upgrade hints point to Prepare Upgrade (U)** — Instead of directing users to manually edit ISC → sync → day2, the hint points to the guided Prepare Upgrade flow.
- **TUI: improved DISCO bundle wizard** — Cleaner no-archives path (loop with "Check Again" / "Exit"), tighter payload summary, back-navigation to local/remote choice.
- **TUI: remember execution mode** — The confirm-and-execute dialog highlights the user's previous choice (Terminal / Terminal auto-answer / TUI).
- **TUI: improved Install Cluster dialog** — Shows "VMware/ESXi" (not "vmw"), "sno (single node)" shorthand, "MAC template" instead of "MAC prefix".
- **Cleaner output** — Condensed post-load/sync hints, suppressed next-step hints in TUI mode, cleaner oc-mirror log output, simplified bundle messages.
- **`aba install` idempotent** — Running `aba install` on an already-installed cluster now exits cleanly with guidance instead of cascading through the dependency chain.
- **`run_once()` debug logging** — Comprehensive `aba_debug` logging at all key decision points (TTL expiry, lock contention, wait timeout, reset) with full command strings for troubleshooting.
- **Improved `--help` text** — Rewritten `aba cluster --help` with structured layout, examples, and SSOT reminder. `-y` description updated to "Answer yes to all prompts" across all help files.
- **Post-install instructions mention TUI** — Users see "aba (or abatui)" in bundle instructions.
- **Default `reg_host` to local hostname** — New mirror installs default `reg_host` to the machine's hostname instead of the generic "registry".
- **`govc` only downloaded for VMware** — CLI Makefile and `ensure_govc()` skip `govc` download/install when `platform` is not `vmw`.

### Bug Fixes

- **Fix state.sh overriding `ocp_version` after upgrade** — `_state_override_mirror()` no longer exports `ocp_version` from `state.sh`, which after an upgrade sync held the TARGET version and clobbered the `aba.conf` intent. This caused CLI version mismatch errors ("openshift-install version does not match aba.conf") and broken ISC upgrade-path generation.
- **Fix CLI binary permissions** — Added `--no-same-owner` to all `tar` extractions and `chmod a+rx` for `oc-mirror` and `govc` to prevent UID/GID leaks from third-party tarballs. Previously, `oc-mirror` could extract as `984:984` with mode `rwxr-----`, making it unexecutable by non-root users.
- **Fix state override from cluster directory** — `normalize-mirror-conf()` now follows the `mirror.conf` symlink to resolve the actual mirror directory name, fixing silent state override failures when called from a cluster directory.
- **Fix state.sh silent overwrites** — Registry re-install now aborts if an ABA-managed registry is already installed (prevents orphaning). `reg_detect_existing()` aborts instead of silently deleting state when registry is unreachable.
- **Fix config file `#` in values** — Config parser no longer truncates values containing `#` (e.g. registry passwords like `abc#def`). Single/double-quoted values are extracted verbatim; only unquoted values treat whitespace-preceded `#` as a comment.
- **Fix `ask()` interactive logic (Bug #1024)** — The ask function's interactive path was completely inverted: for `ask -n`, typing "y" returned NO and typing "n" returned YES. Rewritten so return 0 always means "yes/proceed".
- **Fix SSH connection drops** — Added `ServerAliveInterval` to SSH config to prevent long-running connections from being dropped by intermediate firewalls.
- **Fix catalog image corruption** — Keep catalog images cached to prevent "layer not known" errors from podman garbage-collecting layers mid-operation.
- **Fix `day2.sh` CatalogSource wait** — Per-PID exit code collection replaces bare `wait`, so a failing CatalogSource correctly aborts `day2` instead of being silently swallowed.
- **Fix broken regcreds symlink** — Skip broken `regcreds` symlink for connected clusters instead of erroring out.
- **Fix bare-metal CIDR prefix** — `prefix_length` split moved outside the platform conditional so it's always exported, fixing bare-metal cluster installs.
- **Fix `govc` transient failures** — Retry `govc` commands on transient vCenter `TaskInProgress` conflicts.
- **Fix `aba delete` cleanup visibility** — Removed `2>/dev/null` from `make clean` in delete so cleanup failures are visible.
- **Fix TUI SSH deadlock** — Set `StrictHostKeyChecking=accept-new` and `BatchMode=yes` for libvirt connection tests, preventing host-key prompts from deadlocking the TUI.
- **Fix ISC hint crash in bundle mode** — ISC hint guard no longer crashes with `exit 1` when running inside a bundle workflow.
- **Fix stale ISC on incremental save** — Non-upgrade incremental saves now bundle the ISC in `aba-transfer.tar`, preventing `aba load` from using a stale local ISC that silently skips images.

### Known Issues

- **ISC upgrade mode broken by state.sh override** — After an upgrade sync, re-viewing or regenerating the ImageSet Config may produce a non-upgrade ISC (`minVersion == maxVersion`) because `state.sh` now holds the target version. Workaround: ensure `aba.conf` holds the correct source version before running Prepare Upgrade. A fix using `ocp_upgrade_from` in `state.sh` is planned.
- **`aba day2` / `aba day2-osus` fails after cross-minor upgrade** — The OSUS channel is derived from `aba.conf`'s `ocp_version` (the install version), not the cluster's actual running version. After a cross-minor upgrade (e.g. 4.20 → 4.21), the script tries to set the old channel. Workaround: manually run `oc adm upgrade channel fast-4.21` (or appropriate channel).

---

## [1.1.3](https://github.com/sjbylo/aba/releases/tag/v1.1.3) - 2026-07-01

Bug fix for upgrade path validation


Bug fix for upgrade path validation

### Bug Fixes

- **Fix upgrade path validation crash** — Fixed a bash syntax error in `verify_upgrade_path_exists` where a line continuation (`\`) followed by a comment caused a pipe parse error, breaking upgrade path checks in air-gapped mirror workflows.

---

## [1.1.2](https://github.com/sjbylo/aba/releases/tag/v1.1.2) - 2026-07-01

Operator catalog refresh


### Improvements

- **Pre-release operator catalogs** — `tools/refresh-catalog-indexes.sh` now auto-detects and downloads pre-release catalogs (4.23, 5.0) by probing `registry.redhat.io` for the immediate next minor version beyond the latest GA release. Pre-release catalogs are always re-downloaded (content changes frequently) and use a relaxed operator threshold (`MIN_OPERATORS_PRERELEASE=10`).
- **Updated shipped catalog indexes** — Refreshed all operator catalog indexes; added 4.23 and 5.0 pre-release catalogs for TUI operator browsing.

---

## [1.1.1](https://github.com/sjbylo/aba/releases/tag/v1.1.1) - 2026-06-30

Upgrade robustness, RC/EC pre-release support, catalog performance, TUI hardening, and 80+ bug fixes


Upgrade robustness, RC/EC pre-release support, TUI hardening, catalog performance, and 80+ bug fixes

### New Features

- **RC/EC pre-release version support** — Full support for pre-release OpenShift versions (e.g. `4.22.0-rc.1`, `4.23.0-ec.2`). CLI tools download from `ocp-dev-preview/` paths; TUI wizard and menus handle pre-release version strings correctly.
- **Network auto-detection** — DNS, gateway, and machine network auto-detected at cluster creation time from the host's active interface, instead of at `aba.conf` creation. Existing `cluster.conf` files also get auto-detected values when missing.
- **`aba cluster-version`** — Quick TCP probe to check if a cluster's API is reachable, plus display the cluster's current version without a full `oc` login.
- **Pre-flight version check** — Validate that the source OpenShift version exists in the target channel's Cincinnati graph before running `oc-mirror save/sync`, preventing wasted time on impossible upgrade paths.
- **Upgrade version picker** — TUI upgrade menu queries available versions from the mirror registry and validates them against the Cincinnati upgrade graph before allowing selection.
- **Auto-detect upgrade target from mirror** — `aba upgrade` automatically detects the target version from mirrored release images when no `--to` is specified.
- **Semver-aware version resolution** — Version comparisons and resolution now handle pre-release suffixes (`-rc.N`, `-ec.N`) correctly throughout the codebase.
- **Config drift detection** — Warn when `mirror.conf` or `cluster.conf` values diverge from the installed state (e.g. `reg_host` changed after registry install).
- **`--upgrade-to none`** — Clear the upgrade target version via CLI (`aba --upgrade-to none`) or TUI ("Clear target" option in the upgrade picker).
- **Dynamic oc-mirror URL** — Download URL and version displayed during mirror operations; adapts to the installed OCP version.

### Improvements

- **Structured upgrade pre-flight checks** — Replace brittle string-grepping of `oc adm upgrade` output with structured `ClusterVersion` condition checks (`Failing`, `Upgradeable`, `Progressing`) and `availableUpdates` JSON validation. Clear, actionable error messages with links to Red Hat documentation.
- **Day-2 CA certificate handling** — Detect when the registry CA certificate has changed and append the new CA to the cluster trust bundle (preserving the old CA), preventing `ImagePullBackOff` after registry reinstall.
- **Cluster channel auto-alignment** — `aba day2` automatically sets the cluster's update channel to match `ocp_channel` from `aba.conf`, fixing OSUS graph mismatches when mirrored channel differs from cluster default.
- **Registry SSH pre-flight** — Quay install pre-flight now verifies SSH to localhost, auto-starting `sshd` and configuring keys if SSH fails.
- **TUI upgrade gate dialog** — Word-wrap `oc adm upgrade` output in the upgrade gate dialog for readability; auto-size dialog dimensions.
- **TUI performance** — Eliminate 4-5 second pause on menu return by refactoring mirror recheck to avoid redundant registry probes.
- **Input validation hardening** — 15+ input validation bugs fixed across core scripts and TUI (metacharacter escaping, path validation, format checks).
- **Upgrade safety** — TUI pre-flight gate check rejects downgrades and validates upgrade path before proceeding.
- **Validate upgrade target** — Validate upgrade target version against the channel's Cincinnati graph before `oc-mirror save/sync` operations.
- **Minimum disk reduced** — Minimum disk space requirement reduced from 200 GB to 150 GB.
- **Combined pre-flight** — Internet connectivity and pull-secret checks combined into a single pre-flight for save/sync operations.
- **Disk-space warning** — Disk-space check during `reg-save` changed from abort to warning, allowing the user to proceed.
- **Dynamic vSphere label** — Preflight dialog dynamically shows "ESXi" or "vSphere" based on detected platform.
- **README documentation** — Expanded TUI section, added proxy mode documentation, RC/EC pre-release docs, and fixed broken table/commands.
- **Kubeadmin password masked** — `show_error()` output masks the kubeadmin password to prevent accidental exposure in logs.
- **Catalog download performance** — Skopeo content-layer digest probe (~1s) skips the full podman pull + extract pipeline (~15s/catalog) when catalog data hasn't changed. Repeat `aba mirror isconf` drops from ~39s to ~1.3s. Works across all architectures (amd64, s390x, arm64, ppc64le).
- **Catalog image cleanup** — Catalog container images removed after extraction, saving ~1-2 GB per catalog on disk.

### Bug Fixes

- **ESXi variable leak (Bug #618)** — Clear inherited `GOVC_DATACENTER` and `GOVC_CLUSTER` on standalone ESXi detection, preventing `govc` failures when switching between vCenter and ESXi targets.
- **State override robustness** — State override uses `clusterstate` symlink instead of glob matching, preventing stale state leaks.
- **`replace-value-conf` hardening** — Multiple fixes: auto-quote shell metacharacters, handle tilde in values, correct `-v ''` (empty value) behavior, upsert mode for new keys, comment-out on empty value instead of clearing.
- **Security: config input injection (Bug #405)** — Block backtick, dollar sign, and backslash in TUI config inputs to prevent shell injection.
- **Robust `aba delete` (Bugs #317, #465, #470)** — Kill orphaned monitor processes, handle corrupted state directories, clean stale ISO files.
- **`--type` flag (Bug #313)** — `--type` flag now updates existing `cluster.conf` instead of being ignored.
- **Atomic Docker image save** — `docker-reg-image.tgz` saved atomically to prevent corruption from interrupted writes.
- **Catalog container leak** — Prevent catalog containers from leaking as running processes after index extraction.
- **Skip Quay tarball for Docker** — Skip Quay tarball extraction when `reg_vendor=docker`.
- **Auth backup override (Bug #919)** — Fix `auth.backup` override that could overwrite valid credentials during sync preflight.
- **Conditional update gate (Bug #889)** — Handle `AdminAckRequired` and other conditional update gates in `cluster-upgrade.sh`.
- **DNS/NTP normalization** — Normalize space-separated and tab-separated DNS/NTP input to commas.
- **Pull secret JSON validation (Bug #497)** — Validate JSON format when using an existing pull secret file.
- **DISCO wizard gate (Bugs #571, #880)** — Wizard stays open when install is cancelled; gate drops correctly to action menu on failure.
- **DISCO menu cursor (Bug #886)** — Menu cursor starts on correct item (View ISC) instead of Install Registry.
- **Internet pre-check (Bug #333)** — Pre-check internet connectivity before allowing DISCO-to-Connected mode switch.
- **Upgrade dry-run error (Bug #508)** — Show actual error message when upgrade dry-run fails instead of generic failure.
- **Registry vendor refresh (Bug #516)** — Refresh registry vendor from `mirror.conf` in TUI Settings menu.
- **Operator basket detection (Bug #509)** — Detect operator basket content changes, not just size.
- **Upgrade target persistence (Bug #512)** — Don't persist upgrade target version before user confirms.
- **MAC validation (Bug #514)** — Don't clear all MACs on single validation error.
- **Upgrade cancel (Bug #511)** — Clear target version on Cancel in upgrade manual entry.
- **Day-2 platform message (Bug #515)** — Show platform-appropriate message in Day-2 Startup.
- **Mirror reinstall dialog (Bug #306)** — Show reinstall dialog when mirror is installed but unverified.
- **Bundle path validation (Bug #413)** — Validate bundle path rejects single quotes.
- **Page-1 edits (Bug #506)** — Preserve page-1 wizard edits across `_cluster_generate_defaults` regeneration.
- **Externalized cluster support (Bugs #524, #526)** — `_day2_status()` and related functions use `cluster_kubeconfig()` for externalized clusters.
- **Config comment stripping (Bugs #523, #519)** — Strip inline comments in cluster config drift detection.
- **Install-complete marker (Bug #528)** — Back up `.install-complete` marker and check externalized kubeconfig in auto-detect.
- **Pipefail leak (Bug #525)** — Remove `pipefail` leak from `fetch_all_versions()`.
- **Mirror reg port (Bugs #479, #441)** — Fix mirror registry port parsing; TUI rejects IP address for `reg_host`.
- **VM resources display** — VM resources page shows memory and disk values with correct units.
- **ISC stale cache** — Eliminate stale mirror cache after failed operations and wizard version changes.
- **Dialog spacing** — Consistent dialog spacing via smart `\n<space>` wrapper in `dlg()`.
- **`show_help` blank line (Bug #936)** — Blank line in help text no longer breaks the Interfaces page.
- **`aba tui` guard** — Prevent calling `aba tui` directly (use `abatui` instead).
- **Gateway shift bug** — Fix gateway IP shift when switching between cluster configurations.
- **Stale `ocp_version` in bundle** — Fix stale OCP version in bundle prerequisites.
- **ISC regeneration visibility** — ISC regeneration errors now visible to the user instead of silently swallowed.
- **`run_once` TUI fix** — Skip `run_once` self-healing validation for TUI background checks.
- **Pull-secret diagnostics** — Improved pull-secret mismatch diagnostics with user-facing paths.

---

## [1.1.0](https://github.com/sjbylo/aba/releases/tag/v1.1.0) - 2026-06-15

Major new TUI v2, vSphere preflight, improved upgrade workflow, and reliability improvements


### New Features

- **TUI v2** — Complete rewrite of the interactive terminal UI with shared library (`tui-lib.sh`), wizard mode for guided setup, advanced menu for power users, in-terminal command execution with retry on failure, operator browsing with instant catalog indexes, and dynamic state display in menu titles.
- **vSphere Preflight Validation** — Multi-layer pre-install checks for vSphere environments: TCP/TLS connectivity, authentication, resource existence (datacenter, cluster, datastore, network, resource pool, folder), write-access privilege verification, and DVS-nested network resolution. Emits per-check `[OK]/[FAIL]/[INFO]` report with warning/error counters. Supports both vCenter and standalone ESXi hosts. (@mateuszslugocki)
- **Externalized state management (ADR-007)** — Mirror and cluster state persisted to `state.sh` files, enabling state-aware normalization, automatic detection of background-completed clusters, and directory recreation from state.
- **Pre-built operator catalog indexes** — Ship catalog index files for the latest 6 GA OCP versions, enabling instant operator browsing in the TUI without network access.
- **Smart `starting_ip` default** — Compute starting IP from the machine network CIDR instead of using a static placeholder.
- **Smart catalog refresh** — `tools/refresh-catalog-indexes.sh` now compares the actual operator content digest (not the whole image digest) to detect real operator updates and avoid false re-downloads from base-image security rebuilds.
- **AI/ML operator set** — New `op_sets=ai` option bundles GPU Operator, Node Feature Discovery, SR-IOV, Kueue, cert-manager, and ServiceMesh for AI/ML workloads.
- **Cluster config CLI flags** — New `--host-prefix`, `--master-prefix`, and `--worker-prefix` flags for `aba cluster`.

### Improvements

- **Install script UX** — Styled sequential output with green checkmarks, bold banner, actionable error messages showing the failed command and retry instructions. Git clone progress noise suppressed.
- **CLI version tracking** — `cli/Makefile` and `templates/Makefile.cluster` now rebuild binaries automatically when `ocp_version` changes in `aba.conf`. Stale `openshift-install-mirror` binaries are detected and re-extracted.
- **Quay password validation** — Reject backtick, double-quote, single-quote, and dollar sign characters that break the upstream `mirror-registry` installer. Validated in both CLI (`verify-mirror-conf`) and TUI.
- **CLI flag targeting with `--name`** — `--ntp`, `--dns`, `--gateway`, `--domain`, and `--machine-network` flags now correctly target the named cluster's `cluster.conf` instead of the current directory.
- **TUI lock contention** — Offer to terminate an existing TUI session when the lock is already taken.
- **vSphere folder path** — Automatically append `cluster_name` to vSphere folder path for OCP 4.21+ compatibility.
- **vSphere object validation** — Verify vSphere objects (datacenter, network, datastore, etc.) exist during `vmware.conf` validation with `govc find`.
- **Firewall port cleanup** — Close registry firewall port on `aba uninstall`.
- **CLI tarball corruption recovery** — Detect and re-download corrupt CLI tarballs instead of failing silently.
- **Hardened `replace-value-conf`** — Escape sed/grep metacharacters to prevent config corruption with special-character values.
- **`run_once` surgical kill** — `_kill_id` preserves `cmd.sh` across TTL expiry instead of killing sibling processes.
- **Trace file size guard** — Prevent 29GB trace files when stdout is piped.
- **`aba delete` cleanup** — Now runs `make clean` to remove stale ISO files and build artifacts in addition to deleting VMs.
- **Upgrade CLI binaries** — `aba -d mirror save` downloads CLI binaries for the target version in parallel (via `run_once`), with copy instructions for disconnected upgrades.
- **Cluster creation pipeline** — All `cluster.conf` variables (`mac_prefix`, `ssh_key_file`, `mirror_name`, `hostPrefix`, `master_prefix`, `worker_prefix`) now flow correctly through `aba cluster --name` creation.
- **Bundle ISC protection** — Bundled `imageset-config.yaml` is preserved on the disconnected side until `aba load` completes, preventing ISC regeneration mismatch.
- **v4.22 operator catalogs** — Shipped catalog indexes updated to include OCP v4.22.

### Bug Fixes

- **ESXi detection failure** — `normalize-vmware-conf()` failed to detect standalone ESXi because template defaults (`GOVC_DATACENTER=Datacenter`) caused `govc about` to error out before the HostAgent check could match. All subsequent `govc` commands then failed with "Datacenter not found".
- **ESXi network validation** — Use `host.portgroup.info` instead of `govc find` for network validation on standalone ESXi, where `govc find` may not list all port groups.
- **DNS misconfiguration is fatal** — Reverted DNS checks to `aba_abort` (exit immediately) instead of warning-and-continue.
- **CLI download race condition** — Fix concurrent tarball download corruption and allow `aba delete` without triggering CLI download.
- **`set -e` crash prevention** — Replace `[ ] && cmd` patterns with `if/then/fi` across core scripts to prevent silent crashes under `set -e`.
- **Normalize truncation** — Remove awk field-width bug that truncated long config values.
- **Platform toggle persistence** — TUI platform toggle (`vmw`/`kvm`) now correctly persists to `aba.conf`.
- **Two-tier cert hostname check** — Registry reinstall validates both short and FQDN hostnames against the existing certificate.
- **Orphaned catalog containers** — Use EXIT trap to prevent container leaks during catalog index downloads.
- **MAC prefix uppercase** — Fix MAC address prefix generation to use uppercase hex consistently.
- **TUI auth credential destruction** — Prevent TUI background prefetch from overwriting mirror authentication credentials.
- **TUI SIGPIPE race** — Prevent race condition in `isconf` background tasks that could cause spurious pipe errors.
- **Bundle load failure** — Bundled ISC was regenerated from local config on disconnected side (missing `ocp_upgrade_to`), causing "no release images found" during `oc-mirror load`.
- **Quay `reg_port` ignored** — Mirror-registry install was ignoring custom `reg_port` setting.
- **`make-bundle.sh` crash** — `local` keyword used outside a function caused bash error on bundle creation.
- **Upgrade admin-ack** — Improved guidance when `Upgradeable=False` condition blocks upgrade.
- **Upgrade dry-run** — Always lists available versions; relaxed health check to avoid false blockers.
- **Mirror symlink breakage** — Re-link mirror symlinks in `setup-cluster.sh` after `cluster.conf` creation updates the mirror path.
- **Pull secret hostname mismatch** — `aba register` now reconciles pull secret hostname with current registry configuration.

### Community

- **Mateusz Slugocki** (@mateuszslugocki) — vSphere preflight validation: 42 commits implementing multi-layer connectivity, authentication, resource existence, and privilege verification checks with comprehensive E2E test coverage.
- **Kamil Blaz** (@KamilBlaz) — Mermaid workflow diagram (#29), VM provider refactor with explicit KVM/vSphere contract.

---

## [1.0.2](https://github.com/sjbylo/aba/releases/tag/v1.0.2) - 2026-05-07

New aba upgrade command, trace logging, bug fixes and reliability improvements


New `aba upgrade` command, trace logging, improved error recovery, and future OCP readiness.

### New Features

- `**aba upgrade` command** — Upgrade air-gapped OpenShift clusters via the local mirror registry. Idempotent (exit 0 when already at target), OSUS-aware (uses `oc adm upgrade --to` when a local update graph is detected), resumes monitoring if an upgrade is already in progress. Enriched `--dry-run` queries the mirror registry for available versions higher than current. Flags: `--to <version>`, `--skip-day2`, `--force`, `--dry-run`.
- `**aba show-op-sets` command** — List all available operator sets with their descriptions (parsed from `templates/operator-set-*`). Also available as `aba op-sets`.
- **Trace logging** — Every `aba` invocation captures full stdout+stderr to `~/.aba/logs/trace.log` for post-mortem debugging. Last 5 invocations are rotated (`trace.log.0` through `trace.log.4`).

### Bug Fixes

- **ISC regeneration guard** — `rm mirror/data/.created && aba -d mirror imagesetconf` failed to regenerate because bash `-nt` returns true when the right-hand file is missing. Fixed to explicitly check for `.created` absence.
- `**aba_warning` for user-edited ISC** — When the ISC was manually edited, ABA now warns and preserves edits instead of silently skipping regeneration.
- `**run_once` error recovery** — Add `.DELETE_ON_ERROR` to Makefiles that download files so partial/corrupt downloads are removed on recipe failure. Detect and clean zombie tasks (no exit file, lock free) caused by SIGKILL/OOM/crash. Close lock FD in `setsid` children (`9>&-`) so lock releases immediately. Show stderr tail + yellow recovery hint on failure: *"If this problem persists, re-run './install' from the ABA directory to clear the task cache."*
- **Upgrade flow hardening** — Always run `day2` before upgrade (signatures, IDMS, catalogs). Fix arch mismatch: use `uname -m` (`x86_64`) not Go-style (`amd64`) for release image tags. Add upgrade-already-in-progress preflight check.
- **VM delete guards** — `kvm-delete.sh` and `vmw-delete.sh` exit 0 early if config files are missing (nothing to delete). `kvm-delete.sh` only removes disk volumes, not cdrom ISO.
- **Remote Docker post-install race** — Add 3-attempt retry loop to handle timing race where registry hasn't loaded htpasswd yet. Display actual curl error instead of suppressing with `2>&1`.
- **Sigstore lookaside URLs** — Add `registry.redhat.io` and `registry.access.redhat.com` lookaside URLs so podman signature verification works when ABA's user-level `registries.d` config overrides system defaults.
- **Premature `data_dir` mkdir** — Env var is set early but the directory is only created immediately before oc-mirror runs, preventing empty trees on early abort.
- **Podman catalog error visibility** — Remove `2>/dev/null` from `podman pull/run/cp` commands; capture stderr and pass it to `aba_abort` so the root cause is visible.
- `**oc-command.sh` stdout pollution** — `grep` leaked matched lines to stdout and `aba_info` printed to stdout, corrupting captured command output (e.g. `aba run --cmd 'oc get ...'`). Fixed with `grep -q` and `>&2`.
- **Spinner and color loss after trace logging** — The `exec > >(tee ...)` for trace logging replaced stdout with a pipe, causing `[ -t 1 ]` to return false and disabling the spinner and all colored output. Fixed by saving the original TTY file descriptor before `exec tee` and using it for terminal detection.
- `**ABA_BUILD` stamp opt-in** — `pre-commit-checks.sh` only updates the build timestamp with `--update-build`, avoiding noisy diffs on every commit.

### Improvements

- `**--domain` CLI alias** — `--domain` is now accepted as a synonym for `--base-domain` / `-b`.
- `**.PRECIOUS: mirror.conf`** — Prevents `make` from deleting `mirror.conf` on recipe failure (`.DELETE_ON_ERROR` interaction).
- `**polkit` added to internal RPMs** — Required for Quay rootless registry install (`loginctl enable-linger`).
- `**aba delete --force`** — New `--force` flag removes the entire cluster directory after deleting VMs and stamp files, enabling clean re-creation without manual `rm -rf`.
- **CLI flag refactoring** — Extracted repeated `if cluster.conf else BUILD_COMMAND` pattern into shared `_set_cluster_conf()` helper, reducing ~120 lines of duplication across 15+ flag handlers.
- `**ensure_govc` / `ensure_virsh` in `_ensure_hv_ready`** — Hypervisor CLI tools are automatically ensured before VM operations.
- **Ctrl-C skip hints** — `cluster-startup` adds "(Ctrl-C to skip)" to nodes Ready, console, and cluster operators waits. NTP MCO wait reduced from 60s to 20s.
- **vmw-upload validation** — Validate ISO exists before upload, verify remote size after transfer.
- **README restructure** — New README layout with TUI screenshots, decision tree, dedicated Connected Installation section, operator-set documentation.
- `**macs.conf` documentation** — Added bare-metal MAC address assignment documentation to README (create `macs.conf` in cluster directory with one MAC per node per port).
- **Consecutive `aba_warning` lint** — New pre-commit check detects consecutive `aba_warning`/`aba_abort` calls that should be combined into multi-arg form.

### E2E Testing

- `**set -e` in e2e_run subshells** — Multi-command blocks now fail immediately on first error instead of silently continuing. Exposed and fixed multiple latent test bugs.
- **Cleanup safety** — Dispatcher and framework never `rm -rf` mirror directories; only check `.available` marker to detect stale registries.
- **Mixed cleanup strategies** — Suites exercise `aba reset --force`, `rm -rf`, and `aba clean` to simulate real user behavior.
- **ISC preservation tests** — New tests for back-to-back upgrades and user-edited ISC preservation.
- **Golden VM SSH key deployment** — Copy bastion's `id_rsa` keypair to golden VM instead of generating a new key, so VMs can SSH back to bastion for notification relay. Fail hard if bastion keypair is missing.
- **Upgrade test suites** — New `suite-upgrade` and `cluster-ops` upgrade tests exercise the full `aba upgrade` lifecycle including dry-run, OSUS, and monitoring.
- **DNS auto-detection** — Deploy manifest and pool infra improvements for DNS resolution on conN/disN hosts.
- **Framework improvements** — Adaptive polling, per-pool locks, hung-suite detection, colored banners, deploy manifest updates.

---

## [1.0.1](https://github.com/sjbylo/aba/releases/tag/v1.0.1) - 2026-04-26

Bug fixes and reliability improvements

### Bug Fixes

- **oc-mirror catalog digest pinning** - Workaround for oc-mirror v2 bug ([OCPBUGS-81712](https://issues.redhat.com/browse/OCPBUGS-81712)) where disk2mirror (load) tries to contact upstream registries for catalog tags even in air-gapped environments. ABA now captures image digests during `podman pull` and substitutes them into a temporary `imageset-config-digest.yaml` for all oc-mirror operations (mirror2disk/save, mirror2mirror/sync, disk2mirror/load). The bug only manifests on load, but pinning is applied uniformly for consistency. Transparent to the user; disable with `OC_MIRROR_PIN_CATALOGS=0`.
- **OSUS CSV cleanup** - `day2-config-osus.sh` now deletes stale ClusterServiceVersions during cleanup, preventing `ConstraintsNotSatisfiable` errors on retry.
- **s390x/ppc64le platform selection** - `install-config.yaml` template now forces `platform: none` for System Z and Power architectures (non-SNO), which only support user-provisioned infrastructure.
- **OSUS pre-flight check** - Removed `2>&1` from `oc get` command substitutions in pre-flight checks so stderr messages are visible for debugging and not captured into variables (causing false positives).
- **Bundle archive contents** - `VERSION`, `CHANGELOG.md`, and `LICENSE` now included in bundle archives.
- `**ABA_VERSION` corruption guard** - `pre-commit-checks.sh` now validates that `ABA_VERSION` is a semver string, catching merge conflicts that could overwrite it with a timestamp.
- `**day2-ntp` API unavailable after NTP config** - `day2-config-ntp.sh` now waits for all MachineConfigPools to finish updating (node reboots) before verifying chrony.conf and NTP sources. Previously, the script could exit while the MCO was still rebooting nodes, leaving the API server unreachable for the next command.
- **CLI flag loss via `aba cluster -n`** - When using `-n` (name-based) instead of `-d` (directory-based), 5 CLI flags (`num_workers`, `num_masters`, `vlan`, `ssh_key_file`, `mirror_name`) were silently lost because they weren't forwarded through the Makefile -> `setup-cluster.sh` -> `create-cluster-conf.sh` chain. Additionally, re-running `aba cluster -n` on an existing `cluster.conf` ignored all 13 cluster flags. Fixed by adding a `replace-value-conf` override block in `setup-cluster.sh` that applies CLI-passed values after initial generation.

### Improvements

- `**--mirror-name` flag** - New CLI flag (`aba cluster -n mycluster --mirror-name mymirror`) for named mirror (enclave) workflows. Writes `mirror_name=` to `cluster.conf`.
- **Removed `--proxy`/`--no-proxy` flags** - Dead flags replaced by `--int-connection` (`-I proxy`/`-I direct`/`-I disconnected`).
- `**register`/`unregister` help and docs** - `aba register -h` and `aba unregister -h` now show mirror help (was falling through to generic help). Added `register`/`unregister` to main command list in `aba -h`, added `--reg-port` example to README, fixed error messages to include `register` keyword. Added `OC_MIRROR_PIN_CATALOGS` to `~/.aba/config` template.
- **Graceful Ctrl-C handling** - `aba_wait_show` callers (shutdown, startup, NTP waits) now detect SIGINT/SIGTERM and print "Aborted" instead of "Timed out". Startup messages show actionable errors.
- `**is_bundle_mode()` helper** - New function in `include_all.sh` for clean bundle/DISCO environment detection. `cli-install-all.sh` now skips download waits in bundle mode.
- **Hardened `cli-download-all.sh`** - Added contract header, proper option parsing, `make` error handling, and tool name validation.
- **Reduced default retry counts** - Bundle save and example `--retry` values reduced from 7-8 to 2, matching typical network reliability.

### E2E Testing

- **Infra-owned `aba` binary on disN** - Deployed to `~/.e2e-harness/bin/aba` via `sync_dis_aba()`, ensuring cleanup always has access to `aba uninstall` regardless of user-space state. Fixes INFRA FAIL death spiral when `aba` was missing from PATH on non-interactive SSH.
- `**--fresh` flag** - New `--fresh` (`-F`) alias for `--force` (`-f`) to re-run all suites from scratch with a friendlier name.
- **NTP chronyc verification** - Airgapped suite NTP test switched from `oc debug` to `aba ssh --cmd 'chronyc sources'` with `e2e_poll_remote` for reliable polling.
- **Dispatcher daemon mode** - New `run.sh daemon` auto-restarts the dispatcher on crash with exponential backoff (30s-300s), max 5 consecutive crashes, and Telegram notifications.
- **Early RC write** - `runner.sh` writes the suite exit code immediately after the suite exits, preventing lost PASS results if the runner is killed before final write.
- **Colored banners** - Prominent PASS/FAIL/SKIP/INFRA banners in dispatcher output for suite completion and infrastructure rebuild phases.
- **Per-pool locks** - Replaced global `flock` with per-pool locks, allowing concurrent `run.sh` operations on different pools.
- **Hung-suite detection** - No-output watchdog (default 60 min) notifies operators about potentially hung suites. Fixed false positives caused by `stat` not dereferencing `summary.log` symlinks.
- **Adaptive polling** - Replaced fixed 30-second sleep with adaptive interval (5-30s) that resets on state changes.
- **Cleanup deduplication** - Consolidated 5 duplicated cleanup code blocks into shared `_run_cleanup_on_host()`.
- **Deploy manifest** - Explicit `.deploy-manifest` file lists paths for source deployments.
- **Bundle mode verification** - Airgapped suites now verify `.bundle` flag file and bundle banner after install.

---

## [1.0.0](https://github.com/sjbylo/aba/releases/tag/v1.0.0) - 2026-04-21

Stability, reliability and UX improvements

Stability and reliability improvements.

### Improvements

- **Unified spinner/progress UI (`aba_wait_show`)** - All long-running polling loops (cluster startup, VM power-on/off, OSUS install, day2 operations) now use a consistent background spinner with timeout display, replacing inconsistent dot-printing and silent waits. Includes `parse_duration()` for human-readable time config values.
- **Improved VM annotations** - VMware VM annotations now show richer metadata (cluster name, role, network, install date, console/API URLs). Added `virsh desc` annotations for KVM VMs. Condensed to 5 lines for readability; KVM descriptions persisted to XML.
- **Reliable `aba delete`** - Verified VM destruction with config regeneration. `aba delete` now exits 0 on no-op (already deleted), deregisters deleted clusters properly, and ensures symlinks via `make init` after a clean.
- **Shared oc-mirror retry loop** - Extracted `_run_oc_mirror_with_retry` into `include_all.sh`, consolidating retry logic across save/load/sync. Exit code shown in retry messages. `OC_MIRROR_SINCE` made configurable via `~/.aba/config` (use a far-back date to force full archives instead of differential).
- **Hardened shutdown** - 40-minute timeout with `aba_abort` on failure; exit code properly propagated. VM start/stop scripts converted to `aba_wait_show` with 40-min timeout.
- **Better install failure messages** - Actionable recovery hint shown when `./install` fails, guiding the user to check prerequisites.
- **Cleaner output** - Day2 operations show condensed progress; spinner displays max timeout; startup curl noise suppressed.
- **ESXi compatibility** - `normalize-vmware-conf` adds `VC_FOLDER` fallback for standalone ESXi hosts (no vCenter). Proper ESXi detection for non-VC environments.
- `**GOVC_RESOURCE_POOL` fix** - Removed hardcoded `resourcePool` from example install-configs; simplified placeholder resolution to avoid path duplication.
- **Removed generated mirror scripts** - Eliminated `*-mirror.sh` wrapper scripts; oc-mirror execution is now inlined, reducing confusion about which script actually runs.

### Bug Fixes

- `**reg-save.sh` missing `normalize-mirror-conf`** - `reg-save.sh` did not source `normalize-mirror-conf`, silently ignoring `data_dir` from `mirror.conf`. This caused oc-mirror caches and `TMPDIR` to default to `$HOME` instead of the configured larger partition. Fixed by adding the missing `source`.
- **Bundle builds forced full archives** - `OC_MIRROR_SINCE` was being applied to bundle builds, causing oc-mirror to create full archives on every run instead of reusing cached data across bundle types of the same OCP version. Disabled for bundle workflows.
- `**aba delete` after `aba clean`** - Ensure symlinks are recreated via `make init` so `aba delete` works even after a `make clean`.
- `**sudo` vs `$SUDO` consistency** - Fixed hardcoded `sudo` calls to use `$SUDO` variable, and enabled `loginctl linger` for Docker registry (rootless Podman user session persistence).
- **Grep noise on missing cleanup files** - Silenced harmless grep errors when cleanup state files don't exist yet.
- **Typo in warning messages** - Fixed "IMPORANT" to "IMPORTANT" across warning messages.

### E2E Testing

- **Symlink-safe ABA installation** - New `e2e_install_aba` helper function replaces 12 duplicate inline install blocks across suite files. Uses `rm -rf ~/aba/* ~/aba/.??*` pattern to preserve symlinks for root user disk redirection.
- **Root disk space via symlinks** - Golden VM now creates `/root/aba -> /home/root/aba` and `/root/tmp -> /home/root/tmp` symlinks during provisioning, redirecting disk-heavy directories to the larger `/home` partition. `data_dir` mechanism handles oc-mirror cache redirection.
- **Robust `dnf update` in golden VM** - Uses `nohup` + polling instead of inline execution, preventing SSH timeout during long OS updates.
- **Color-coded output** - Bold blue for remote commands (improved color-blind accessibility), distinct formatting for local vs remote execution.
- **CDN resilience** - Staggered pool startup, `subscription-manager refresh` before installs, fail-on-exhaustion for CDN rate limits.
- **Randomized suite order** - `--all` now randomizes suite execution order to surface ordering-dependent bugs.
- **Pool 4 enabled** - Full 4-pool E2E execution support.
- **Suite notifications** - Command ring buffer, enriched start/done notifications via Telegram, relayed through SSH to bastion for disconnected pools.
- **Bundle improvements** - Delete test cluster before upload to free resources sooner; build oldest/missing bundle types first; clean up work dir after successful upload.

---

## [0.9.9](https://github.com/sjbylo/aba/releases/tag/v0.9.9) - 2026-04-01

Hardening, stability and bug fixes

### Improvements

- **Graceful shutdown resilience** - Debug pod warmup timeout increased to 90s (from 30s) for slow image pulls. Warmup failure now warns and attempts shutdown via SSH fallback instead of aborting. Shutdown `oc debug` timeout increased to 60s. Compact single-line wait progress output.
- **Day2 cluster health checks** - `day2`, `day2-osus`, and `day2-ntp` now show a one-liner warning when cluster operators or MCP are degraded/updating, replacing the blocking 30-minute MCO wait.
- **Updated `operator-set-ai`** - Replaced `serverless-operator` with `gpu-operator-certified` and `nfd`. Updated mesh from v2 to v3 (`servicemeshoperator3`). Added `rhcl-operator` (Red Hat Connectivity Link).
- **Renamed `operator-set-ocpv` → `operator-set-virt`** - Consistent naming for the virtualization operator set.
- **Consistent SSH config** - All `ssh`/`scp` calls in ABA scripts now use `-F ~/.aba/ssh.conf`, eliminating noisy host-key warnings and ensuring uniform connection settings (`cluster-rescue.sh`, `kvm-upload.sh`).

### Bug Fixes

- **False oc-mirror failure from stale error files** - Save, load, and sync share `data/working-dir/logs/`. A leftover `mirroring_errors_*.txt` from a previous operation caused the next run to report failure even when oc-mirror succeeded. Stale error files are now cleared before each oc-mirror attempt with a warning logged.
- **Pasta hairpin fix for rootless Podman 5.x** - `int_down()` now unconditionally adds a device-only default route so `pasta` networking can handle hairpin connections (host connecting to its own FQDN/IP). Fixes "Connection reset by peer" during mirror-registry install on RHEL 9 with rootless Podman.
- **CLI download retry in bundle creation** - `scripts/make-bundle.sh` now retries CLI binary downloads (3 attempts, 30s backoff) to handle transient network failures during `aba bundle`.
- **OSUS operator install resilience** - `day2-config-osus.sh` now waits for MCO rolling updates to complete before creating the OSUS subscription, preventing OLM unpack job failures due to node instability. Includes automatic retry on subscription timeout, pre-flight cleanup of stale subscriptions, and skips the MCO wait entirely on re-run when OSUS is already installed.
- **Stale Quay container on re-install** - `reg-uninstall-quay.sh` now removes leftover containers that block a fresh install.
- **Bundle script idempotency** - `ip route add` no longer fails with "File exists" on re-run; removed unreliable `oc-mirror` executability check.
- **v2 bundle pipeline TEMPLATES_DIR** - Fixed path that incorrectly pointed to old v1 templates. v2 templates (README, VERIFY, UNPACK) are now self-contained under `bundles/v2/templates/`.

### E2E Testing

- **Periodic Telegram notifications** - Dispatcher now sends status updates every 10 minutes from its own in-memory state, replacing the unreliable external monitor script.
- **Pool registry purge** - `setup-pool-registry.sh` now purges extraneous repositories from the pool registry, preventing disk exhaustion on conN hosts.
- **Bundle suite /tmp fix** - Changed bundle tests to use `~/tmp/delete-me` instead of `/tmp/delete-me` to avoid "No space left on device" on small `/tmp` partitions.
- **Refactored `run.sh` deploy tarball** - Consolidated three duplicate `tar` commands into `_make_source_tar()`, ensuring `test/lib.sh` is always deployed to conN hosts (including with `--dev`).
- **Fixed `--pool N` vs `--pools N` semantics** - `--pool N` now targets a single specific pool for all operations (deploy, detect, dispatch); `--pools N` sets the range 1..N. Previously `--pool N` behaved like `--pools N`.
- **Fixed suite completion detection** - `_detect_running_and_completed` now only considers completed results from the target pool when `--pool N` is set, preventing stale results on other pools from blocking dispatch.
- **Bundle maker test hardening** - Removed subshell pattern that silently swallowed test script failures; now relies on `set -e` for immediate abort. Cluster VMs left alive on failure for debugging.
- **ODF StorageCluster timeout** - Increased from 600s to 1800s (30 min) in `test-odf.sh` to accommodate Ceph OSD self-healing during MCO rolling reboots. Outer per-module timeout raised to 2700s (45 min).
- **Banner timing** - `echo_step` in `bundle-test-lib.sh` now shows wall clock time and elapsed since last banner (e.g. `(17:38:45 / 2m10s)`).
- **Log collection fix** - `_collect_pool_logs` no longer prints errors when `~/.e2e-harness/logs/` doesn't exist on disN; logs separated into per-pool subdirectories.

---

## [0.9.8](https://github.com/sjbylo/aba/releases/tag/v0.9.8) - 2026-03-29

KVM platform support, more flexible preflight checks, sigstore-aware oc-mirror 4.21 compatibility, bug fixes and improvements

### New Features

- **KVM/libvirt platform support** - Full KVM hypervisor support as a new platform alongside VMware and bare-metal. Includes 11 `kvm-*.sh` lifecycle scripts (create, delete, start, stop, kill, ls, exists, on, refresh, upload, create-folder), `kvm.conf` template, and `ensure_virsh()` helpers. Supports non-root SSH to the KVM host.
- **Externalized Makefile targets** - 19 targets (info, login, shell, day2, shutdown, startup, create, delete, ls, start, stop, kill, etc.) moved from `Makefile.cluster` into `aba.sh` case handlers, enabling three-way platform dispatch (vmw/kvm/bm) via `_ensure_hv_ready()`.
- **Bundle v2 pipeline** - New idempotent `bundles/v2/` pipeline with numbered phase scripts, per-step log files, and combined log in `work/`. Replaces monolithic `bundle-create-test.sh`. Supports stale work-dir cleanup and retry.
- **Podman-based catalog extraction** - Operator catalog indexes are now extracted directly from container images using podman, replacing the oc-mirror dependency for operator listing. Faster startup, no oc-mirror wait for catalog downloads, and more accurate default channel detection.
- **Display names in TUI** - Operator search results and basket view now show display names (e.g. "Red Hat Integration - AMQ Broker") alongside operator package names.
- **Search by display name** - TUI operator search matches against both operator names and display names (case-insensitive).
- **Catalog extraction hardening** - Generic JSON fallback for unknown directory formats, runtime completeness check, and end-of-extraction summary for any parsing issues.
- **Pre-flight validation** - DNS, NTP reachability and IP conflict detection before ISO generation, integrated as a Make dependency ([#22](https://github.com/sjbylo/aba/pull/22), [@mateuszslugocki](https://github.com/mateuszslugocki)).
- **Configurable preflight strictness** - `verify_conf=all/conf/off` controls validation: `all` (default) runs full network checks, `conf` validates config files only, `off` skips all. Use `aba --verify conf` when the bastion is on a different network than cluster nodes.
- **Sigstore-aware mirroring** - Per-registry sigstore signature control via `~/.config/containers/registries.d/aba-sigstore.yaml`. Preserves cosign signatures for OCP release images (`quay.io/openshift-release-dev`) and Red Hat images (`registry.redhat.io`), required for OCP 4.21+ `ClusterImagePolicy` verification, while allowing unsigned certified/community operator images to mirror without errors. Optional `OC_MIRROR_FLAGS` in `~/.aba/config` for additional oc-mirror flags.
- **Auto-detect network values** - When domain, machinenetwork, dnsservers, nexthopaddress, or ntpservers are empty in `aba.conf` at cluster creation time, they are auto-detected and written back so the user can review before proceeding.

### Changed

- **Consolidated mirror data directories** - `mirror/save/` and `mirror/sync/` merged into single `mirror/data/` directory. Imageset config template renamed to `imageset-config.yaml.j2`.
- `aba reset` now cleans up `.index/` directory (cached catalog indexes).
- Catalog download dialog shows OCP version.
- Error messages reference `aba catalog` instead of `oc-mirror list operators`.
- `aba kill` and `aba delete` now warn (instead of abort) when `agent-config.yaml` is missing.
- Show hint to skip network checks when preflight has warnings or errors.
- ISC reminder message shows operator hint only when no operators are configured.
- Stale podman `render-*` temp dirs cleaned up after catalog extraction.
- Ask user before bumping master memory for OCPBUGS-62790 workaround.
- Release image error message now includes captured skopeo stderr.
- MAC addresses quoted in `agent-config.yaml` example files to match generated YAML.
- `shutdown --wait` properly passed through to `cluster-graceful-shutdown.sh` (was silently dropped). Shutdown now has 5-minute timeout with progress messages instead of infinite silent wait.
- Full banner shown only on first v2 bundle step; short header for subsequent steps.
- Suppress `cd` stderr in `run_once()` to avoid noise in TUI output.

### Bug Fixes

- **SNO install failure with `verify_conf=conf`** - `verify-release-image.sh` was skipping `openshift-install` binary extraction from the mirror when `--verify conf` was used. The fallback generic binary embeds quay.io URLs, causing `SignatureValidationFailed` in OCP 4.21+. Fix: `--verify conf` now only skips the skopeo connectivity check, not binary extraction. Extracted binary filename simplified to `openshift-install-mirror-$reg_host`.
- `**vmware.conf`/`kvm.conf` symlink regression** - Externalization removed auto-symlink creation. `_ensure_hv_ready()` now conditionally creates symlinks if missing.
- **Arping IP conflict detection on multi-homed hosts** - Fixed `arping -I` interface selection.
- **Podman state corruption** - Enable systemd lingering on conN hosts; removed destructive `rm -rf containers/storage` and `systemctl --user stop --all`.
- `**int_down` failing when interface already disconnected** - Graceful handling of already-down interfaces.
- **KVM lifecycle fixes** - Fixed QXL video error on headless hosts, `virsh start` on already-active domains, `on_reboot=restart` alongside `on_poweroff=restart`, SNO VM naming via `vm_name()` helper, and graceful shutdown in disconnected/KVM environments.
- **Cluster startup infinite loops** - Fixed VIP DNS resolution and `int_down` idempotency during startup.
- `**oc debug` in disconnected environments** - Fixed cluster lifecycle commands that failed because `oc debug` tried to pull images from the internet.
- **Bundle pipeline fixes** - Tightened idempotency check in `00-setup-connectivity.sh` (requires `README.txt`), added `exit 1` on make failure in `go.sh`, fixed `oc-mirror v2 --help` requiring `--v2` flag, updated default `GIT_BRANCH`.
- **Bundle Makefile** - Error when `OP_SETS` missing for non-release bundles.

### E2E Testing

- `**--revert` flag** - `run.sh run --revert` reverts all pool VMs (conN+disN) to their `pool-ready` snapshots before starting tests, giving a clean baseline and reclaiming VMware thin-disk bloat.
- **Suite banner** - Banner now reads `SUITE START:` for clearer log boundaries.
- **Live view scrollback** - Removed `tmux clear-history` so scrolling up in the live view shows previous suite output.
- **Dashboard fix** - Fixed stale dashboard content caused by `tail -F` not detecting symlink target changes; background monitor restarts the stream on suite change without screen flicker.
- **DISPATCH colorization** - `DISPATCH:` and `FORCE DISPATCH:` output highlighted in bold cyan.
- **Reduced VM disk size** - `VM_DISK_EXTRA_GB` reduced from 100 to 0; template's 522 GB is sufficient for all suites.
- **Dispatcher audit fixes** - Replaced all `(( var++ ))` with `var=$(( var + 1 ))` (crash under ERR trap), prevented duplicate suite dispatch, fixed CPU spin, fixed final summary to include rescheduled suites.
- **Rescheduled suite priority** - Injected suites now dispatched before the normal work queue.
- **Duplicate operator guard** - Prevents `cincinnati-operator` from being appended twice to `imageset-config.yaml` during upgrade tests.
- **User action logging** - Interactive prompt actions (retry, skip, restart-suite, abort) now reflected in dashboard summary.
- **Cleanup robustness** - `PIPESTATUS[0]` captured in cleanup pipelines to prevent masking failures. Cleanup failures now halt the suite. Removed 137 inappropriate `2>/dev/null` that hid error info. Post-suite integrity checks for orphan VMs and leftover registry containers.
- **KVM lifecycle suite** - SNO full install + VM lifecycle (ls/stop/start/kill/shutdown/startup), plus compact and standard boot validation.
- **Regression test** - `verify_conf=conf` mirror binary extraction test added to prevent SNO install regression.

### Community

- [@mateuszslugocki](https://github.com/mateuszslugocki) - Pre-flight validation for DNS, NTP and IP conflicts ([#22](https://github.com/sjbylo/aba/pull/22))

---

## [0.9.7](https://github.com/sjbylo/aba/releases/tag/v0.9.7) - 2026-03-15

Quay/Docker now first-class, improved abatui, easier existing registry support and many fixes

### New Features

- **Named mirrors** - `aba mirror --name mymirror` creates an isolated mirror directory (like named clusters). Multiple enclaves each get their own credentials and config.
- **Existing-registry registration** - Register an external registry with `--pull-secret-mirror` and `--ca-cert` flags. ABA stores credentials locally and never touches the registry. Deregister with `aba -d mirror unregister`.
- **Docker registry as first-class citizen** - New `reg_vendor` setting in `mirror.conf` (values: `auto`, `quay`, `docker`). `auto` selects Quay on x86_64/s390x/ppc64le, Docker on arm64. All install/uninstall commands now work through a unified dispatcher (`reg-install.sh`) that handles vendor selection, local/remote deployment, and the full lifecycle. Both Quay and Docker registries support remote installation via SSH.
- **Expanded CLI options** - New flags: `--vendor`, `--reg-port`, `--reg-host`, `-A`/`--api-vip`, `-G`/`--ingress-vip`, `-W`/`--num-workers`, `--num-masters`, `--vlan`, `--ssh-key`, `--proxy`, `--no-proxy`, `--data-disk-gb`, `-Y`/`--yes-permanent`. Removed fake short flags that weren't wired up.
- **Idempotent registry install** - If the registry is already healthy, `aba install` continues instead of failing.
- **Wildcard DNS detection** - DNS checks now detect wildcard entries and soften failures to warnings instead of aborting.
- **Shared catalog index** - Catalog index files stored in `aba/.index/` with symlinks per mirror dir, avoiding redundant downloads across mirrors.
- **ISC dependency tracking** - ISC regeneration respects operator and `mirror.conf` changes; configurable catalog TTL.
- **Single RPM install batch** - All RPMs installed in one `dnf` call instead of individually.
- **Release hotfix mode** - `release.sh --hotfix` for quick patch releases.

### Changed

- **Registry credentials moved to persistent location** - `mirror/regcreds/` contents (pull secret, root CA) now stored in `~/.aba/mirror/<mirror-name>/`, surviving `aba clean` and `aba reset`. A convenience symlink `mirror/regcreds -> ~/.aba/mirror/mirror/` is created for browsing.
- **Multi-mirror support foundation** - New `mirror_name` setting in `cluster.conf` (default: `mirror`) binds a cluster to a specific mirror directory. Credentials scoped per mirror name.
- **Registry script architecture** - Monolithic `reg-install.sh` refactored into thin dispatcher + shared library (`reg-common.sh`) + vendor-specific scripts (`reg-install-quay.sh`, `reg-install-docker.sh`) + generic SSH orchestrator (`reg-install-remote.sh`). Same pattern for uninstall. Shared functions extracted and improved (getent fallback for DNS, unified firewall handling).
- **Makefiles consolidated** - Mirror and cluster Makefiles moved to `templates/`; mirror flags respect `-d`.
- **Marker rename** - `.installed`/`.uninstalled` markers renamed to `.available`/`.unavailable` for clarity.
- **Vendor-neutral messages** - Registry log and error messages no longer assume Quay.

### TUI

- **Settings persist** - Registry type (Quay/Docker) and "ask before big steps" saved to and reloaded from config files, including values with inline comments.
- **Exit button on Pull Secret dialog** - Escape is no longer the only way out.
- **ISC race condition fixed** - Background ISC generation no longer deletes save-dir ISC prematurely; System Z timestamp equality handled.
- **Basket works on fresh install** - Empty basket no longer appears when no operators are selected on first run.

### Bug Fixes

- **Quay resource check warns, not aborts** - Pre-flight CPU/memory check logs a warning instead of blocking install.
- **Docker `--network host`** - Docker registry and pool registries use host networking, fixing pasta/hairpin issues.
- **CLI download race fixed** - `oc-mirror` and other CLI downloads complete before catalog fetches start.
- **Stale credential detection** - Fresh installs no longer blocked by leftover credentials from previous runs.
- `**aba reset` guarded** - Won't reset if registry is still installed; `aba clean` removes working-dir properly.
- `**grep -q` removed everywhere** - Eliminates SIGPIPE killing bash in pipelines.
- **Shutdown respects `-y`** - Cluster shutdown prompt honors `-y` flag and `ask=false`.
- **Retry on cluster shutdown** - Retry logic and failure reporting added.
- **Tarball extraction hardened** - Removed `|| true` masks; added gzip integrity guards.
- **Remote registry fixes** - Correct auth/data-dir paths, Docker image tarball existence check before scp, uninstall fallbacks.
- **Stale-state detection** - Reordered before FQDN check in registry install; Quay SSH fallback added.
- **ISC regeneration guard for System Z** - Handles timestamp equality on platforms with coarse clocks.
- **TUI vendor setting applied correctly** - Docker selection no longer lost when `mirror.conf` doesn't exist yet.
- **TUI inline-comment handling** - Settings loaded from config files that have trailing `# comments`.
- **Double `[ABA]` prefix removed** - Clean log output.
- **OSUS error improved** - Mentions CatalogSource sync delay.
- **Registry UX** - Breadcrumb navigation, reinstall warnings, load save-dir guard.
- **Version mismatch check** - No longer skips `save/` when `sync/` is auto-generated.
- `**run_once` validation** - Uses saved command+CWD pair for accurate state tracking.
- **CLI downloads skipped for housekeeping** - `aba clean`, `aba reset`, and similar commands no longer trigger downloads.
- **Catalog YAML always regenerated** - Fresh index download triggers ISC regeneration.
- `**reg_detect_existing()` fixed** - No longer blocks fresh installs due to stale credentials.
- **Docker remote install** - Ensures `docker-reg-image.tgz` exists before scp.
- **Nested directories in custom manifests** - Day2 custom manifest support now handles nested directory structures ([#20](https://github.com/sjbylo/aba/pull/20), [@mateuszslugocki](https://github.com/mateuszslugocki))

---

## [0.9.6](https://github.com/sjbylo/aba/releases/tag/v0.9.6) - 2026-02-25

Custom manifests, oc-mirror tuning, IP validation, and bug fixes

### New Features

- **Custom manifest support (agent-based installer)** - Place `.yaml`/`.yml` files in `openshift/` or `manifests/` directories in a cluster folder to embed custom Kubernetes manifests (MachineConfig, networking, storage) into the agent-based ISO at bootstrap time ([#18](https://github.com/sjbylo/aba/pull/18), [@mateuszslugocki](https://github.com/mateuszslugocki))
- **Custom manifest support (day2)** - Place `.yaml`/`.yml` files in `day2-custom-manifests/` to have them automatically applied during `aba day2`, after oc-mirror resources and signatures ([#19](https://github.com/sjbylo/aba/pull/19), [@mateuszslugocki](https://github.com/mateuszslugocki))
- **oc-mirror parallel images setting** - New `OC_MIRROR_PARALLEL_IMAGES` in `~/.aba/config` (default 8) controls `--parallel-images` for save/load/sync, useful for reducing concurrency on slow or unreliable networks
- **oc-mirror image timeout setting** - New `OC_MIRROR_IMAGE_TIMEOUT` in `~/.aba/config` (default 30m) controls the `--image-timeout` for save/load/sync
- **IP-in-CIDR validation** - `cluster.conf` validation now checks that `starting_ip`, all node IPs, `api_vip`, and `ingress_vip` fall within `machine_network`; error messages show the valid IP range
- **Makefile bootstrap target** - New `aba bootstrap` follows the install dependency chain up to `agents-up`, then monitors bootstrap progress

### Improvements

- `**aba ls` auto-installs govc** - Running `aba ls` now installs `govc` automatically if it is missing
- **Release script `--ref` support** - Release from a specific older commit on dev, useful when dev has moved ahead of what was tested

### Bug Fixes

- **CA cert permissions** - Use `install -m 644` instead of `sudo cp` so CA certs are readable by non-root users; fixes "certificate signed by unknown authority" TLS failures
- `**cluster.conf` override by `aba.conf`** - Fixed source order in `vmw-create.sh` so per-cluster `machine_network` is no longer clobbered by `aba.conf`, fixing IP validation failures for VLAN clusters
- **Congratulations box colors** - Green borders with distinct white, cyan, and yellow text instead of uniform color
- `**ASK_OVERRIDE` unbound variable** - Guarded with `${ASK_OVERRIDE:-}` in four places so scripts are safe under `set -u`

### E2E Test Framework

- `**e2e_poll` / `e2e_poll_remote` helper** - New wall-clock-bounded polling functions replace count-based retries for condition checks (e.g. `e2e_poll 600 30 "desc" "cmd"` = poll every 30s, timeout after 10 minutes)
- `**-q` (quiet) flag for `e2e_run`** - Suppress command output to log file only; used for background wait steps
- **Failure prompt: flush TTY buffer** - Stale keystrokes no longer cause accidental command execution at the interactive `[R]etry` prompt
- **Failure prompt: `!` prefix for commands** - Custom commands now require `!` prefix (e.g. `!ls -la`); unrecognized input shows a hint instead of executing as a shell command
- **Failure prompt: default indicator** - Prompt shows `[R]etry` (uppercase) to indicate Enter defaults to retry
- **Fix pool-specific `mirror.conf` hostname** - `sed` pattern now uses `registry.$(pool_domain)` instead of hardcoded `registry.example.com`, fixing registry hostname replacement for multi-pool runs
- **Fix dnsmasq VLAN binding** - Strip restrictive `listen-address` from `/etc/dnsmasq.conf` after install so dnsmasq listens on all interfaces (lab, VLAN, loopback), fixing DNS resolution for VLAN cluster nodes
- **Fix `run_once` state check pipe** - Removed `| head -3` from `ls` pipeline that masked exit code due to missing `pipefail`
- **Fix missing regcreds for mirror config tests** - `suite-connected-public.sh` test [8] now uses real pool registry credentials (superseded by `DIS_HOST` → `CON_HOST` fix below)
- **Add `assert_file_exists` guards** - File existence checks before `grep` on `install-config.yaml` and `cluster.conf` in `suite-connected-public.sh`, `suite-network-advanced.sh`, and `suite-airgapped-local-reg.sh` to aid debugging
- **Remove `|| cat` anti-pattern** - Removed fallback `|| cat` from `grep` in `suite-airgapped-local-reg.sh` that masked test failures
- **Improve test descriptions across all suites** - Clarified 30+ ambiguous descriptions: "bastion" → "internal bastion", "dir" → "cluster dir", "Verify cluster operators" → "Show cluster operator status", "via sed" → "manually", and other accuracy fixes
- **Rename vCenter folder `abatesting` → `aba-e2e`** - Renamed `VC_FOLDER` default path across all E2E files (13 files, 24 occurrences) for clearer naming
- **Add missing DNS records for SNO variants** - Added dnsmasq entries for `sno-mirror`, `sno-proxyonly`, and `sno-noproxy` cluster types in pool-lifecycle.sh
- `**run.sh dash` command** - New `run.sh dash [N] [log]` opens a multi-pane tmux window tailing test logs on remote conN hosts; auto-detects pool count from `pools.conf`, adapts layout (horizontal for 1-3, grid for 4+)
- **Fix `DIS_HOST` → `CON_HOST` in connected test** - Test [8] in `suite-connected-public.sh` was pointing the mirror at `dis1.example.com` (unreachable) instead of `con1.example.com`; now uses real pool registry credentials instead of dummies
- **Golden VM stays connected** - Removed `_vm_disconnect_internet` from golden VM prep; only disN pool VMs get disconnected after cloning, matching the working v1 approach
- **Snapshot guard before cloning** - Refuse to clone pool VMs if `golden-ready` snapshot doesn't exist, preventing broken pool VMs from incomplete golden prep
- **Add testy user to pool VM configure** - `_vm_create_test_user` added to both `_configure_con_vm` and `_configure_dis_vm` for robust user setup after cloning
- **Conditional network disconnect** - `_vm_disconnect_internet` only modifies `ens224.10` if it exists and only brings down `ens256` if active, avoiding errors on VMs without those interfaces
- **Remove all `grep -q` from e2e scripts** - Removed 91 instances across all test files so command output is always visible for debugging
- **Fix tmux dashboard pane label mismatch** - Panes now self-set titles via OSC escape sequences instead of relying on `tmux select-pane -T` index assumptions
- **Fix `run.sh live` hang on Mac** - Replaced heredoc (`cat <<LIVEOF`) with `echo` block to avoid CRLF line-ending issues that prevented heredoc terminator recognition
- **Improved `--recreate-vms` messaging** - Shows "will be recreated" instead of misleading "VMs not ready" when VMs are about to be refreshed
- **Remove `2>&1` from testy SSH verification** - SSH warnings no longer merged into stdout, preventing string comparison failures

### Documentation

- `**2>&1` rule in Rules of Engagement** - Added: only use `2>/dev/null` or `2>&1` when there is an explicit reason

---

## [0.9.4](https://github.com/sjbylo/aba/releases/tag/v0.9.4) - 2026-02-18

Catalog download fixes, TUI improvements, and reliability bug fixes

### New Features

- **Catalog download throttling** - New `CATALOG_MAX_PARALLEL` setting (default 3) controls parallel operator catalog downloads, preventing 401 authentication errors and timeouts with registry.redhat.io
- **TUI pull-secret-first wizard** - Pull secret moved to the first wizard step, enabling operator catalog prefetch to begin as early as possible

### Improvements

- **First-install congratulations banner** - Improved visual presentation with colored box on successful first install
- **TUI settings display** - Current settings shown inline on the Settings menu item
- **Network configuration display** - Show network configuration during cluster setup
- **Image load retries** - Increased retry count for image loading reliability

### Bug Fixes

- **Catalog download crash** - Fixed arithmetic evaluation (`running++` with `set -e`) that silently aborted catalog downloads after the first catalog, causing "ImageSet configuration file not found" errors
- **Catalog prefetch visibility** - Removed silent `2>/dev/null` suppression from catalog prefetch; errors now visible for debugging
- **Bundle/save without registry** - `aba bundle` and `aba save` no longer fail when the registry binary download is unavailable; the download is attempted but non-fatal
- **Gateway detection** - `get_next_hop()` now correctly identifies the gateway for subnets where the common gateway IP is outside the local range
- **Misleading "Creating cluster.conf"** - No longer shows "Creating" message when `cluster.conf` already exists on retry
- **TUI SIGINT crash** - Ctrl-C during command execution no longer crashes the TUI
- **run_once file descriptor leak** - Closed inherited file descriptors to prevent `tee` blocking on subprocess exit
- **iptables fallback** - Firewall rules now work on systems without firewalld (falls back to iptables directly)
- **Docker registry sync retry** - Added missing retry flag for TUI Docker registry sync operations
- **Docker registry connectivity check** - Early connectivity check prevents cryptic failures during Docker registry install
- **Mirror clean state reset** - `run_once` task state properly reset during mirror clean/reset
- **arm64 mirror-registry** - mirror-registry download now fails gracefully on arm64 instead of downloading the wrong architecture binary
- **Architecture-aware downloads** - Fixed mirror-registry download and SSH check for non-x86 architectures
- **Mirror Makefile cleanup** - Fixed glob bug, typos, and removed dead code

---

## [0.9.3](https://github.com/sjbylo/aba/releases/tag/v0.9.3) - 2026-02-13

Multi-architecture fix, improved release process and docs

### Improvements

- **Release script `--dry-run` flag** - Preview releases safely without making any changes
- **Release post-tag verification** - Automated checks that VERSION, ABA_VERSION, CHANGELOG, and README are correct in the tagged commit
- **Release workflow docs rewritten** - Documents both HEAD and ref-based flows, dry-run usage, common pitfalls, and quick reference
- **Install `gh` CLI** - GitHub CLI now available for automated GitHub release creation
- **README cleanup** - Removed stale content, fixed inconsistencies, broadened architecture references, improved install description

### Bug Fixes

- **s390x/ppc64le architecture support** - Fixed architecture mapping that caused x86 or arm64 binaries to be downloaded on s390x (System Z) and ppc64le (Power) systems
- **Install update detection** - Uses `diff` to compare file contents instead of timestamp comparison, fixing false "up-to-date" when switching between dev and release builds
- **Test SSH scripts** - Added `exit 0` to prevent spurious failures when final informational SSH call times out
- **Duplicate RPM packages in install script** - Deduplicated the package list to avoid redundant entries in the install output

---

## [0.9.2](https://github.com/sjbylo/aba/releases/tag/v0.9.2) - 2026-02-13

TUI polish, new E2E test framework, reliability and UX fixes

### New Features

- **TUI promoted to stable** - Removed "Experimental" label, renamed to `abatui.sh`, added root symlink `./abatui`
- **Older version option** - TUI version selection now offers Latest, Previous, and Older (N-2 minor release)
- **Version display** - `aba --aba-version` now shows the semantic version (e.g. v0.9.2)
- **E2E test framework** - New three-tier architecture (coordinator/connected bastion/internal bastion) with pool-aware helpers, per-pool DNS via dnsmasq, and parallel test execution support
- **TUI automated tests** - New test suites for basic flow, full wizard, and early-exit cleanup

### Bug Fixes

- Fixed `run_once` race condition (TOCTOU) in validation and guarded unbound variables
- Fixed `run_once` "Error: Task not started" message suppressed in quiet wait mode
- Fixed download-before-install sequencing so `ensure_*()` functions wait for downloads
- Fixed TUI network auto-fill: values only populated in bundle mode (disconnected), no longer overwritten in connected environments
- Fixed TUI resume dialog appearing on fresh start when `aba.conf` was auto-created
- Fixed TUI deletes auto-created `aba.conf` on early wizard exit for a clean slate
- Fixed TUI symlink path resolution so `./abatui` works correctly
- Fixed misleading "Downloading CLI" message when CLIs already installed

### Improvements

- TUI exit shows consistent summary with modified files, log path, and help hints
- TUI Settings and action dialogs now have inline Help buttons
- TUI help text clarifies Save/Bundle (mirror-to-disk) vs Sync (mirror-to-mirror) operations
- TUI simplified `isconf` execution by removing unnecessary confirmation dialog
- Shared TUI constants (`tui-strings.sh`) for dialog titles and menu IDs
- `--aba-version` documented in help text
- CLI tools download in parallel via `cli-download-all.sh` filtering
- Version-aware download task IDs prevent stale cache across OCP version changes
- E2E suites use pool-aware helpers instead of hardcoded IPs

### Community

- [@sylviyayy](https://github.com/sylviyayy) - Added FAQ section and Day 2 documentation to README

---

## [0.9.1](https://github.com/sjbylo/aba/releases/tag/v0.9.1) - 2026-02-08

Bug fixes and improvements

### Bug Fixes

- Fixed TUI hang: use dynamic version in catalog peek checks
- Fixed segfault caused by tar extracting incomplete tarball during download
- Fixed bundle creation with non-standard directory names ([#13](https://github.com/sjbylo/aba/pull/13), [@mateuszslugocki](https://github.com/mateuszslugocki))
- Fixed race condition in run_once validation logic
- Use mv instead of cp for error files to prevent false failures
- Added error handling for all ensure_*() function calls
- Fixed 'Version unavailable' error
- Fixed 'missing release image' error for wrong channel/version combination
- Fixed `oc-mirror list operators` requiring `--v1` flag ([#11](https://github.com/sjbylo/aba/pull/11), [@KamilBlaz](https://github.com/KamilBlaz))

### Improvements

- Added log rotation and history file to run_once()
- Always install all RPM packages for both connected and disconnected environments
- Removed oc-mirror v1 mirroring code and oc_mirror_version variable
- Removed duplicate ensure_oc_mirror() call in reg-sync.sh
- Removed redhat-marketplace catalog references

### Community

- [@KamilBlaz](https://github.com/KamilBlaz) - Fixed oc-mirror operator listing ([#11](https://github.com/sjbylo/aba/pull/11))

---

## [0.9.0](https://github.com/sjbylo/aba/releases/tag/v0.9.0) - 2026-01-26

First release

### Core Features

- Air-gapped OpenShift installation and management
- Agent-based installer support (SNO, compact, standard clusters)
- Mirror registry setup (mirror-registry and docker-registry)
- CLI tool management (oc, openshift-install, oc-mirror, govc, butane)
- Bundle creation for disconnected environments
- VMware vCenter/ESXi integration
- Operator catalog management

### New Features

- **TUI** - Interactive wizard for guided disconnected installation setup (`./abatui`)
- **Versioning** - Check your ABA version with `aba --aba-version`

### Improvements

- **Faster bundle creation** - CLI tools now download in parallel
- **Better validation** - Real-time OpenShift version checking with clear error messages
- **Improved feedback** - Progress indicators for long-running tasks, scrollable command output
- **Enhanced UX** - Cleaner screen handling, helpful waiting messages

### Bug Fixes

- Fixed "Task not started and no command provided" error when running `aba -d mirror load` directly
- Fixed `oc-mirror list operators` incorrectly reporting success (exit code 0) when catalog download fails
- Fixed catalog download error detection and reporting
- Corrected bundle filename version suffixing
- Various workflow and error handling improvements

---

## Version Format

`MAJOR.MINOR.PATCH`

- **MAJOR**: Breaking changes (CLI changes, workflow changes)
- **MINOR**: New features (backward compatible)  
- **PATCH**: Bug fixes
