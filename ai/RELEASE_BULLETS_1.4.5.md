# ABA 1.4.5 Release Highlights

OpenShift 5 readiness with enhancements and bug fixes.

### New features

- **Continuous bare-metal install** — One `aba install` / `make install` for BM (edit + boot prompts) instead of three Make stops. Recreate primed/transfer artifacts after upgrade (primed remains beta).

### Improvements

- **OpenShift 5 Friendly** — README callout and badge: ready for OpenShift 5 (and OpenShift 4) as new releases land.

### Fixes

- **`aba import --force` will not clobber a healthy managed cluster** — Refuses when ABA already has a valid kubeconfig for that FQDN; `--force` stays for stale/reinstall rebuild only.
- **Upgrade honors Upgradeable=False** — Admin-ack / Upgradeable=False no longer sneaks through on `ask=false`; use `--force` to bypass intentionally.
- **Bare-metal startup follows the installed cluster (regression)** — Power-on prompts again use that cluster's `state.sh`, not the next-install platform in `aba.conf` (a leftover `vmware.conf` no longer sends a BM cluster into `aba start`).
