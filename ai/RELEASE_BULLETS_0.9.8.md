KVM platform support, more flexible preflight checks, sigstore-aware oc-mirror 4.21 compatibility, bug fixes and improvements

### User-facing highlights

- **KVM/libvirt as a first-class platform** — Deploy OpenShift clusters on KVM alongside VMware and bare-metal.
- **Pre-flight validation** — DNS, NTP reachability, and IP conflict detection before ISO generation. Configurable strictness: `--verify all` (default), `--verify conf` (config only), `--verify off`.
- **Sigstore-aware mirroring** — Per-registry signature control via `aba-sigstore.yaml`. Preserves cosign signatures for OCP release images and Red Hat operators while allowing unsigned community images to mirror cleanly. Optional `OC_MIRROR_FLAGS` for additional oc-mirror flags.
- **Podman-based operator catalog** — Operator listing uses podman directly instead of oc-mirror. Faster startup and accurate default channels.
- **TUI: display names and search** — Operator search results and basket show display names. Search matches both package name and display name.
- **Auto-detect network settings** — Empty `aba.conf` values (domain, machine_network, DNS, NTP, gateway) are auto-detected at cluster creation time.
- **Unified mirror data directory** — `mirror/save/` and `mirror/sync/` consolidated into `mirror/data/`.
- **Graceful shutdown improvements** — `shutdown --wait` with 5-minute timeout and progress messages. Fixed shutdown/startup for disconnected and KVM environments.

### Bug fixes

- Fixed `openshift-install` binary extraction with `--verify conf` (caused `SignatureValidationFailed` on OCP 4.21+).
- Fixed arping IP conflict detection on multi-homed hosts.
- Fixed `oc debug` in disconnected environments (cluster lifecycle commands tried to pull from the internet).
- Fixed podman state corruption on E2E pool hosts.
- Multiple KVM lifecycle fixes (headless hosts, already-active domains, graceful shutdown).
- Fixed cluster startup infinite loops (VIP DNS resolution, `int_down` idempotency).

### Community

Thanks to [@mateuszslugocki](https://github.com/mateuszslugocki) for contributing pre-flight validation ([#22](https://github.com/sjbylo/aba/pull/22)) and other features.

Full changelog: [CHANGELOG.md](https://github.com/sjbylo/aba/blob/main/CHANGELOG.md)
