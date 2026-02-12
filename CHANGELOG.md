## [Unreleased]

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
- Fixed bundle creation with non-standard directory names (#13)
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


### Bug Fixes
- Fixed "Task not started and no command provided" error when running `aba -d mirror load` directly
- Fixed `oc-mirror list operators` incorrectly reporting success (exit code 0) when catalog download fails

---

## [0.9.0] - 2026-01-21

### New Features
- **TUI** - Interactive wizard for guided disconnected installation setup (`./abatui`)
- **Versioning** - Check your ABA version with `aba --aba-version`

### Improvements
- **Faster bundle creation** - CLI tools now download in parallel
- **Better validation** - Real-time OpenShift version checking with clear error messages
- **Improved feedback** - Progress indicators for long-running tasks, scrollable command output
- **Enhanced UX** - Cleaner screen handling, helpful waiting messages

### Bug Fixes
- Fixed catalog download error detection and reporting
- Corrected bundle filename version suffixing
- Various workflow and error handling improvements

### Core Features
- Air-gapped OpenShift installation and management
- Agent-based installer support (SNO, compact, standard clusters)
- Mirror registry setup (mirror-registry and docker-registry)
- CLI tool management (oc, openshift-install, oc-mirror, govc, butane)
- Bundle creation for disconnected environments
- VMware vCenter/ESXi integration
- Operator catalog management

---

## Version Format

`MAJOR.MINOR.PATCH`

- **MAJOR**: Breaking changes (CLI changes, workflow changes)
- **MINOR**: New features (backward compatible)  
- **PATCH**: Bug fixes

[Unreleased]: https://github.com/sjbylo/aba/compare/v0.9.2...HEAD
[0.9.2]: https://github.com/sjbylo/aba/releases/tag/v0.9.2
[0.9.1]: https://github.com/sjbylo/aba/releases/tag/v0.9.1
[0.9.0]: https://github.com/sjbylo/aba/releases/tag/v0.9.0
[0.9.0]: https://github.com/sjbylo/aba/releases/tag/v0.9.0
