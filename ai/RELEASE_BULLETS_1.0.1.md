# ABA 1.0.1 - Release Notes

Bug fixes and reliability improvements.

## Bug Fixes

- **oc-mirror catalog digest pinning** -- Workaround for oc-mirror v2 bug ([OCPBUGS-81712](https://issues.redhat.com/browse/OCPBUGS-81712)) where disk2mirror (load) contacts upstream registries in air-gapped environments. ABA now pins catalog digests automatically. Transparent to the user; disable with `OC_MIRROR_PIN_CATALOGS=0`.
- **OSUS CSV cleanup** -- Stale ClusterServiceVersions are now deleted during cleanup, preventing `ConstraintsNotSatisfiable` errors on retry.
- **s390x/ppc64le platform selection** -- `install-config.yaml` now forces `platform: none` for System Z and Power architectures (non-SNO).
- **OSUS pre-flight check** -- Stderr messages now visible for debugging instead of being captured into variables.
- **Bundle archive contents** -- `VERSION`, `CHANGELOG.md`, and `LICENSE` now included in bundle archives.
- **`day2-ntp` API unavailable after NTP config** -- `day2-ntp` now waits for MachineConfigPool rollout to complete before verifying NTP, preventing "connection refused" errors on the next command.

## Improvements

- `**is_bundle_mode()` helper** -- Clean bundle/DISCO environment detection; `cli-install-all.sh` now skips download waits in bundle mode.
- **Hardened `cli-download-all.sh`** -- Added contract header, proper option parsing, `make` error handling, and tool name validation.
- `**ABA_VERSION` corruption guard** -- `pre-commit-checks.sh` validates that `ABA_VERSION` is a semver string, catching merge conflicts.
- **Reduced default retry counts** -- Bundle save and example `--retry` values reduced from 7-8 to 2.