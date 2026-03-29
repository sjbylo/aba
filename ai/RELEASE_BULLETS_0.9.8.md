# Release Message: ABA 0.9.8

## One-liner

**ABA 0.9.8 — KVM platform support, smarter preflight checks, and oc-mirror 4.21 compatibility**

## User-facing highlights

- **KVM/libvirt as a first-class platform** — Deploy OpenShift clusters on KVM alongside VMware and bare-metal. Full VM lifecycle (create, delete, start, stop, kill, shutdown, startup) via `aba.sh`.
- **Pre-flight validation** — DNS, NTP reachability, and IP conflict detection run automatically before ISO generation. Catches misconfigurations early.
- **Configurable validation strictness** — `aba --verify conf` skips network checks when the bastion is on a different network than cluster nodes. Also `--verify off` and `--verify all` (default).
- **Sigstore-aware mirroring** — Per-registry sigstore signature control via `~/.config/containers/registries.d/aba-sigstore.yaml`. Preserves cosign signatures for OCP release images (`quay.io/openshift-release-dev`) and Red Hat operators (`registry.redhat.io`), required for OCP 4.21+ `ClusterImagePolicy` verification, while allowing unsigned certified/community operator images to mirror without errors. Optional `OC_MIRROR_FLAGS` in `~/.aba/config` for additional oc-mirror flags.
- **Podman-based operator catalog** — Operator listing now uses podman directly instead of oc-mirror. Faster startup, accurate default channels, and display names shown in TUI search.
- **Auto-detect network settings** — Empty `aba.conf` network values (domain, machine_network, DNS, NTP, gateway) are auto-detected at cluster creation time.
- **Unified mirror data directory** — `mirror/save/` and `mirror/sync/` consolidated into `mirror/data/`. Simpler layout, fewer gotchas.
- **Bundle v2 pipeline** — Idempotent numbered phase scripts with per-step logs, replacing the monolithic bundle creation script. Easier debugging and retry.
- **SNO install fix for 4.21+** — Fixed `openshift-install` binary extraction when using `--verify conf`, which caused `SignatureValidationFailed` on OCP 4.21 clusters.
- **Graceful shutdown improvements** — `shutdown --wait` properly passed through with 5-minute timeout and progress messages. Fixed shutdown/startup for disconnected and KVM environments.
- **Externalized VM lifecycle** — 19 Makefile targets moved into `aba.sh`, enabling consistent three-way platform dispatch (VMware/KVM/bare-metal).

## Source

Full changelog: [CHANGELOG.md](CHANGELOG.md) under `[Unreleased]`
