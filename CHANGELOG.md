## [Unreleased]

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
- **Auto-detect network values** - When domain, machine\_network, dns\_servers, next\_hop\_address, or ntp\_servers are empty in `aba.conf` at cluster creation time, they are auto-detected and written back so the user can review before proceeding.

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
- **`vmware.conf`/`kvm.conf` symlink regression** - Externalization removed auto-symlink creation. `_ensure_hv_ready()` now conditionally creates symlinks if missing.
- **Arping IP conflict detection on multi-homed hosts** - Fixed `arping -I` interface selection.
- **Podman state corruption** - Enable systemd lingering on conN hosts; removed destructive `rm -rf containers/storage` and `systemctl --user stop --all`.
- **`int_down` failing when interface already disconnected** - Graceful handling of already-down interfaces.
- **KVM lifecycle fixes** - Fixed QXL video error on headless hosts, `virsh start` on already-active domains, `on_reboot=restart` alongside `on_poweroff=restart`, SNO VM naming via `vm_name()` helper, and graceful shutdown in disconnected/KVM environments.
- **Cluster startup infinite loops** - Fixed VIP DNS resolution and `int_down` idempotency during startup.
- **`oc debug` in disconnected environments** - Fixed cluster lifecycle commands that failed because `oc debug` tried to pull images from the internet.
- **Bundle pipeline fixes** - Tightened idempotency check in `00-setup-connectivity.sh` (requires `README.txt`), added `exit 1` on make failure in `go.sh`, fixed `oc-mirror v2 --help` requiring `--v2` flag, updated default `GIT_BRANCH`.
- **Bundle Makefile** - Error when `OP_SETS` missing for non-release bundles.

### E2E Testing
- **`--revert` flag** - `run.sh run --revert` reverts all pool VMs (conN+disN) to their `pool-ready` snapshots before starting tests, giving a clean baseline and reclaiming VMware thin-disk bloat.
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

## [0.9.7] - 2026-03-15

Quay/Docker now first-class, improved abatui, easier existing registry support and many fixes


### New Features
- **Named mirrors** - `aba mirror --name mymirror` creates an isolated mirror directory (like named clusters). Multiple enclaves each get their own credentials and config.
- **Existing-registry registration** - Register an external registry with `--pull-secret-mirror` and `--ca-cert` flags. ABA stores credentials locally and never touches the registry. Deregister with `aba unregister`.
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
- **`aba reset` guarded** - Won't reset if registry is still installed; `aba clean` removes working-dir properly.
- **`grep -q` removed everywhere** - Eliminates SIGPIPE killing bash in pipelines.
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
- **`run_once` validation** - Uses saved command+CWD pair for accurate state tracking.
- **CLI downloads skipped for housekeeping** - `aba clean`, `aba reset`, and similar commands no longer trigger downloads.
- **Catalog YAML always regenerated** - Fresh index download triggers ISC regeneration.
- **`reg_detect_existing()` fixed** - No longer blocks fresh installs due to stale credentials.
- **Docker remote install** - Ensures `docker-reg-image.tgz` exists before scp.

---

## [0.9.6] - 2026-02-25

Custom manifests, oc-mirror tuning, IP validation, and bug fixes


### New Features
- **Custom manifest support (agent-based installer)** - Place `.yaml`/`.yml` files in `openshift/` or `manifests/` directories in a cluster folder to embed custom Kubernetes manifests (MachineConfig, networking, storage) into the agent-based ISO at bootstrap time ([#18](https://github.com/sjbylo/aba/pull/18), [@mateuszslugocki](https://github.com/mateuszslugocki))
- **Custom manifest support (day2)** - Place `.yaml`/`.yml` files in `day2-custom-manifests/` to have them automatically applied during `aba day2`, after oc-mirror resources and signatures ([#19](https://github.com/sjbylo/aba/pull/19), [@mateuszslugocki](https://github.com/mateuszslugocki))
- **oc-mirror parallel images setting** - New `OC_MIRROR_PARALLEL_IMAGES` in `~/.aba/config` (default 8) controls `--parallel-images` for save/load/sync, useful for reducing concurrency on slow or unreliable networks
- **oc-mirror image timeout setting** - New `OC_MIRROR_IMAGE_TIMEOUT` in `~/.aba/config` (default 30m) controls the `--image-timeout` for save/load/sync
- **IP-in-CIDR validation** - `cluster.conf` validation now checks that `starting_ip`, all node IPs, `api_vip`, and `ingress_vip` fall within `machine_network`; error messages show the valid IP range
- **Makefile bootstrap target** - New `aba bootstrap` follows the install dependency chain up to `agents-up`, then monitors bootstrap progress

### Improvements
- **`aba ls` auto-installs govc** - Running `aba ls` now installs `govc` automatically if it is missing
- **Release script `--ref` support** - Release from a specific older commit on dev, useful when dev has moved ahead of what was tested

### Bug Fixes
- **CA cert permissions** - Use `install -m 644` instead of `sudo cp` so CA certs are readable by non-root users; fixes "certificate signed by unknown authority" TLS failures
- **`cluster.conf` override by `aba.conf`** - Fixed source order in `vmw-create.sh` so per-cluster `machine_network` is no longer clobbered by `aba.conf`, fixing IP validation failures for VLAN clusters
- **Congratulations box colors** - Green borders with distinct white, cyan, and yellow text instead of uniform color
- **`ASK_OVERRIDE` unbound variable** - Guarded with `${ASK_OVERRIDE:-}` in four places so scripts are safe under `set -u`

### E2E Test Framework
- **`e2e_poll` / `e2e_poll_remote` helper** - New wall-clock-bounded polling functions replace count-based retries for condition checks (e.g. `e2e_poll 600 30 "desc" "cmd"` = poll every 30s, timeout after 10 minutes)
- **`-q` (quiet) flag for `e2e_run`** - Suppress command output to log file only; used for background wait steps
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
- **`run.sh dash` command** - New `run.sh dash [N] [log]` opens a multi-pane tmux window tailing test logs on remote conN hosts; auto-detects pool count from `pools.conf`, adapts layout (horizontal for 1-3, grid for 4+)
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
- **`2>&1` rule in Rules of Engagement** - Added: only use `2>/dev/null` or `2>&1` when there is an explicit reason

---

## [0.9.4] - 2026-02-18

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

## [0.9.3] - 2026-02-13

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

## [0.9.2] - 2026-02-13

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

---

## [0.9.1] - 2026-02-08

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

### Improvements
- Added log rotation and history file to run_once()
- Always install all RPM packages for both connected and disconnected environments
- Removed oc-mirror v1 mirroring code and oc_mirror_version variable
- Removed duplicate ensure_oc_mirror() call in reg-sync.sh
- Removed redhat-marketplace catalog references

---

## [0.9.0] - 2026-01-26

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

[Unreleased]: https://github.com/sjbylo/aba/compare/v0.9.7...HEAD
[0.9.7]: https://github.com/sjbylo/aba/releases/tag/v0.9.7
[0.9.6]: https://github.com/sjbylo/aba/releases/tag/v0.9.6
[0.9.4]: https://github.com/sjbylo/aba/releases/tag/v0.9.4
[0.9.3]: https://github.com/sjbylo/aba/releases/tag/v0.9.3
[0.9.2]: https://github.com/sjbylo/aba/releases/tag/v0.9.2
[0.9.1]: https://github.com/sjbylo/aba/releases/tag/v0.9.1
[0.9.0]: https://github.com/sjbylo/aba/releases/tag/v0.9.0
