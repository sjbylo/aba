# Changelog

All notable changes to the Aba project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Pre-commit checks script (`build/pre-commit-checks.sh`)
- Generic `run_once` wrapper (`scripts/run-once.sh`) for Makefile integration
- `run_once -q` flag to suppress waiting messages for short-lived tasks
- `run_once -m` flag for custom waiting messages with PID display
- `run_once -e` flag to capture stderr from failed tasks
- Waiting messages for all CLI and mirror tool installations
- Two-phase CLI/mirror tool installation pattern (download → install)

### Changed
- Renamed `--split` bundle option to `--light`
- All CLI tool installations now use `run_once` pattern
- All mirror tool installations now use `run_once` pattern
- Runner directories now use `chmod 711` (traversable but not listable)
- PID files now use `chmod 644` (readable by all users)

### Fixed
- CWD preservation in `run-once.sh` wrapper for correct command execution
- Symlink path resolution in scripts using `pwd -P`
- Missing `INFO_ABA` in scripts called directly from Makefiles
- Bash command substitution bug with `$(<file 2>/dev/null)`
- PID display in `run_once` waiting messages (permissions + bash quirk)
- Catalog files downloaded to wrong directory when using `aba -d mirror/`

### Documentation
- Added comprehensive AI documentation under `ai/` directory
- Updated `RULES_OF_ENGAGEMENT.md` with architectural patterns
- Updated `RUN_ONCE_RELIABILITY.md` with reliability analysis

---

## [0.9.0] - TBD

Initial versioned release.

### Features
- Air-gapped OpenShift installation and management
- Agent-based installer support (SNO, compact, standard clusters)
- Mirror registry setup (mirror-registry and docker-registry)
- CLI tool management (oc, openshift-install, oc-mirror, govc, butane)
- Bundle creation for disconnected environments
- TUI (Text User Interface) for interactive configuration
- VMware vCenter/ESXi integration
- Operator catalog management

---

## Version Format

`MAJOR.MINOR.PATCH`

- **MAJOR**: Breaking changes (CLI changes, workflow changes)
- **MINOR**: New features (backward compatible)  
- **PATCH**: Bug fixes

[Unreleased]: https://github.com/sjbylo/aba/compare/v0.9.0...HEAD
[0.9.0]: https://github.com/sjbylo/aba/releases/tag/v0.9.0
