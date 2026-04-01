Hardening, stability and bug fixes across operator installs, graceful shutdown and mirroring

### Improvements

- **OSUS install hardened** — Operator subscription creation is now retry-safe: detects and cleans up stuck/unhealthy subscriptions before provisioning, retries once on timeout, and writes detailed debug state to `~/.aba/logs/.day2-osus.log` for post-mortem. Poll loops have a 10-minute ceiling to avoid infinite hangs.
- **Graceful shutdown resilience** — Debug pod warmup timeout increased to 90s (from 30s) for slow image pulls. Warmup failure now warns and attempts shutdown anyway (SSH fallback) instead of aborting. Shutdown `oc debug` timeout increased to 60s. Compact single-line progress output replaces per-line spam.
- **Day2 cluster health checks** — `day2`, `day2-osus`, and `day2-ntp` now show a one-liner warning when cluster operators or MCP are degraded/updating, replacing the blocking 30-minute MCO wait.
- **CLI download retry** — `make-bundle.sh` retries failed CLI downloads (oc-mirror, oc, openshift-install) up to 3 times with 30s backoff, recovering from transient network errors.
- **Updated `operator-set-ai`** — Replaced `serverless-operator` with `gpu-operator-certified` and `nfd`. Updated mesh from v2 to v3 (`servicemeshoperator3`). Added `rhcl-operator` (Red Hat Connectivity Link).
- **Renamed `operator-set-ocpv` → `operator-set-virt`** — Consistent naming for the virtualization operator set.
- **Consistent SSH config** — All `ssh`/`scp` calls in ABA scripts now use `-F ~/.aba/ssh.conf`, eliminating noisy host-key warnings and ensuring uniform connection settings.

### Bug fixes

- Fixed false `oc-mirror` failure caused by stale `mirroring_errors_*.txt` files left from a previous save/load/sync operation.
- Fixed stale Quay container left behind during `aba uninstall` on re-install scenarios.
- Fixed pasta hairpin routing for rootless podman: `int_down()` now adds a default route so DNS resolution works after the interface is brought down.
- Fixed bundle script idempotency: `ip route add` no longer fails with "File exists" on re-run; removed unreliable `oc-mirror` executability check.
- Fixed v2 bundle pipeline `TEMPLATES_DIR` pointing to old v1 templates directory. v2 templates (README, VERIFY, UNPACK) are now self-contained under `bundles/v2/templates/`.

Full changelog: [CHANGELOG.md](https://github.com/sjbylo/aba/blob/main/CHANGELOG.md)
