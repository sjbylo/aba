# Release Bullets for v1.2.0

VIP auto-allocation, auto DNS/NTP infrastructure, air-gap transfer guardrails, quay-ng vendor, and VMware reliability fixes.

## New Features

- **VIP auto-allocation** — Multi-node clusters get API/Ingress VIPs auto-allocated from the machine network when ABA manages DNS, eliminating manual VIP assignment.
- **VIP collision detection** — ABA detects IP conflicts before cluster install and aborts with a clear message.
- **Auto DNS/NTP infrastructure** — `aba setup dns` and `aba setup ntp` configure dnsmasq and chronyd on the bastion; per-cluster DNS records are auto-managed at install/delete time.
- **Quay-ng registry vendor [ALPHA]** — New mirror registry option backed by the Go-based Quay mirror-registry rewrite (Quadlet-based, rootless).
- **`aba show-operators`** — List all available operators from the cached catalog index.
- **TUI: Cluster Login Terminal** — New "L" menu item in Day-2 opens an interactive shell pre-logged into the selected cluster.

## Improvements

- **Air-gap transfer guardrails** — `aba load` aborts if `mirror_*.tar` missing, warns if `aba-transfer.tar` missing, offers to clean up archives after successful load.
- **Bundle `--force` preserves oc-mirror state** — Only ABA-owned files are removed; `working-dir/` is preserved across retries.
- **Stderr capture for diagnostics** — Internal commands (dig, curl, govc, skopeo, firewall-cmd, chronyd) now log stderr to trace.log instead of discarding it.
- **Bridge interface detection** — Network auto-detection works correctly on hosts using bridge interfaces (e.g. `br-lab`).
- **Registry uninstall idempotent** — `aba uninstall` succeeds cleanly even when the registry is already removed.

## Bug Fixes

- **Fix `externalize_cluster_state()` source order** — Cluster.conf values now correctly override aba.conf for cluster-specific settings (machine_network corruption on multi-homed bastions).
- **Fix VMware CD-ROM NFS datastore race** — Detects and recovers when NFS-backed ISO fails to connect at VM power-on (reconnects device and resets VM).
- **Fix ISO upload resilience** — Retry logic and post-upload size verification prevent silent zero-byte uploads.
- **Fix CLI download race after version switch** — Downloads no longer skipped when ocp_version changes between operations.
