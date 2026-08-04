# ABA v1.2.1

## Why ABA?

ABA turns disconnected OpenShift deployment from a multi-day, expert-led process into a repeatable workflow that takes hours. It automates registry setup, image mirroring, certificate management, and cluster bootstrapping — and works the same way whether you're connected, partially disconnected, or fully air-gapped.

- **Days to hours** — Automated end-to-end workflows replace manual, error-prone steps
- **No expertise required** — Guided TUI and CLI mean teams don't need deep knowledge of `oc-mirror`, registries, or air-gap networking
- **Fewer transfer failures** — Self-contained bundles with built-in validation catch missing files and stale metadata before they cause problems
- **Consistent at scale** — One tool, three deployment modes, three platforms (VMware, KVM, bare metal). Primed bundles let a central team prepare clusters that remote sites deploy without modification
- **Safer upgrades** — Signature preservation, OpenShift Update Service (OSUS) graph validation, and dependency ordering handled automatically
- **Auditable and secure** — Every deployment is fully documented by its config files and logs. Destructive operations default to "no" to prevent accidental data loss
- **Reduced human error** — Pre-flight validation, idempotent commands, and network auto-detection prevent the most common deployment failures
- **Full lifecycle** — Not just initial install: ongoing operator updates, version upgrades, and day-2 configuration follow the same simple workflow
- **Runs anywhere** — Any terminal on a standard RHEL bastion, via SSH or local console. No web console, no desktop, no browser. Works in banking, FSI, manufacturing OT, and other regulated or air-gapped environments

---

## Release Highlights

- **TUI v2** — Fully rewritten text-based interface with guided wizard mode, operator browsing from pre-built catalog indexes, and step-by-step cluster lifecycle management
- **Full-featured TUI** — `abatui` covers all ABA operations from any SSH terminal — no desktop or browser required in the same network. Runs on all four supported architectures (x86_64, aarch64, ppc64le, s390x)
- **Connected install mode** — Install OpenShift clusters directly from the internet without needing a web console or Hybrid Cloud Console — just SSH and a pull secret
- **Cluster upgrade workflow (BETA)** — `aba upgrade` handles disconnected OCP upgrades end-to-end: mirror target version, apply signatures, manage OSUS, monitor the upgrade
- **TUI upgrade dialog** — Interactive version picker with z-stream/minor grouping, conditional version warnings, and force toggle
- **Guided dependency chains** — `aba upgrade` automatically offers to install OSUS (OpenShift Update Service) and apply day-2 mirror configuration if not already done
- **Disconnected upgrade transfer bundle** — `aba save` creates a self-contained transfer bundle that greatly simplifies data transfer to air-gapped environments; `aba load` unpacks it automatically on the disconnected side
- **Release signature preservation** — Signatures are no longer lost across multiple `oc-mirror` syncs
- **Mirror operation summaries** — `aba sync`, `aba load`, and `aba install` show what succeeded
- **Smart `excl_platform` guards** — Skip re-downloading platform images already mirrored
- **Air-gap transfer guardrails** — `aba load` validates tar contents before unpacking and shows a transfer summary
- **Sigstore-aware mirroring** — Per-registry signature control preserves cosign signatures for OCP 4.21+ `ClusterImagePolicy` verification
- **Bundle extra CLIs for air-gap** — `aba save`/`aba bundle` include virtctl, helm, argocd, etc. for the disconnected side
- **Quay-ng registry vendor (BETA)** — New Go-based Quay mirror-registry option (Quadlet, rootless)
- **Pre-release and future OCP version support** — RC and EC pre-release versions (e.g. `4.22.0-rc.1`) are fully supported across CLI, TUI, mirroring, and upgrades
- **Catalog download performance** — Skopeo digest probe skips unchanged catalogs; repeat `aba mirror isconf` drops from ~39s to ~1.3s
- **Primed bundle workflow (BETA)** — Bundle fully primed cluster configs for the disconnected side — clusters are 100% ready to deploy on arrival with no further configuration needed, reducing deployment time and eliminating manual setup errors
- **TUI Cluster Login Terminal** — One-click shell logged into any cluster with `oc` ready
- **Container image** — Containerfile packages ABA and all dependencies into a single image for bastions with no package manager access
- **vSphere preflight validation** — Multi-layer pre-install checks: connectivity, authentication, resource existence, and write-access privilege verification
- **Network auto-detection** — DNS, gateway, and machine network are pre-filled from the host's active interface at cluster creation time; values can be changed by the user if needed
- **Auto DNS/NTP infrastructure** — `aba setup dns/ntp` configures dnsmasq and chronyd on the bastion with auto-managed per-cluster records (ideal for lab and test environments)
- **VIP auto-allocation** — Multi-node clusters get API/Ingress VIPs assigned automatically when ABA manages DNS
- **VIP collision detection** — ARP probe before install prevents deploying onto conflicting IPs
- **`aba write-usb`** — Guided bare-metal ISO writing with device safety checks and SHA256 verification
- **`aba unstick`** — Bounce stuck pods during cluster installs to recover from transient failures
- **`aba show-operators`** — List available operators from the cached catalog index
- **AI/ML operator set** — `op_sets=ai` bundles GPU Operator, NFD, SR-IOV, Kueue, cert-manager, and ServiceMesh
- **Post-install summary** — Cluster name, version, platform, API endpoint, and next steps shown after install
- **Destructive prompts default to "no"** — Prevents accidental `uninstall`/`delete` operations
- **RHEL 10 support** — RHEL 10 and CentOS Stream 10 added as supported platforms
