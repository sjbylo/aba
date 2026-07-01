# Release Bullets for v1.1.3

## Bug Fixes

- **Fix upgrade path validation crash** — Fixed a bash syntax error in `verify_upgrade_path_exists` where a line continuation (`\`) followed by a comment caused a pipe parse error, breaking upgrade path checks in air-gapped mirror workflows.
