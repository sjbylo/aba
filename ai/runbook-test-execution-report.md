# Runbook Test Execution Report

**Runbook:** Upgrade OCP 4.18 → 4.19 and Migrate to ABA / oc-mirror
**Test Date:** 2026-05-02
**Architecture:** x86_64 (runbook targets s390x; test validates workflow on x86)

---

## Test Environment


| Role                            | Host                 | Details                                      |
| ------------------------------- | -------------------- | -------------------------------------------- |
| Connected Workstation           | bastion              | RHEL 9.7, internet access, ABA source repo   |
| Internal Bastion (disconnected) | registry.example.com | RHEL 9.7, no internet, Docker registry :5000 |
| SNO Cluster                     | sno4.example.com     | VMware VM, 16 vCPU, 32 GB RAM                |



| Parameter          | Value                               |
| ------------------ | ----------------------------------- |
| Source OCP Version | 4.18.38 (latest stable-4.18)        |
| Target OCP Version | 4.19.28 (latest stable-4.19)        |
| Registry Vendor    | Docker v2, port 5000                |
| Old reg_path       | `/ocp4/openshift4`                  |
| New reg_path       | `/ocp/openshift`                    |
| Operators Mirrored | web-terminal, devworkspace-operator |
| ABA Version        | 1.0.1 (build 20260426220357)        |
| oc-mirror Version  | 4.21.0                              |


---

## Phase 0 — Set Up "Existing" Environment

**Objective:** Simulate a pre-existing OCP 4.18 cluster with Docker :5000 mirror, then move ABA aside to replicate a customer without ABA.


| Step | Action                                                  | Result                                                   | Duration |
| ---- | ------------------------------------------------------- | -------------------------------------------------------- | -------- |
| 0.1  | Install fresh ABA on bastion, configure for 4.18.38     | OK — `aba --channel stable --version 4.18 --platform bm` | ~10s     |
| 0.2  | Configure mirror for Docker :5000 at `/ocp4/openshift4` | OK — edited `mirror.conf`                                | ~1s      |
| 0.3  | Generate ISC and save images                            | OK — 19 GB tar (`mirror_000001.tar`)                     | ~15 min  |
| 0.4  | Create bundle and transfer to registry host             | OK — piped via `aba tar --out -` to SSH                  | ~20 min  |
| 0.5  | Install Docker :5000 on registry host                   | OK — `aba -d mirror install`                             | ~40s     |
| 0.6  | Load images into registry                               | OK — `aba -d mirror load`, 380 release images            | ~10 min  |
| 0.7  | Create and install SNO 4.18.38                          | OK — `aba -d sno4 install`, all COs healthy              | ~50 min  |
| 0.8  | Move ABA aside (`~/aba-original`, `~/.aba-original`)    | OK — registry and cluster remain operational             | ~1s      |


**Verification:**

- `oc get clusterversion` → 4.18.38, Available=True
- `oc get nodes` → sno4 Ready
- `skopeo list-tags docker://registry.example.com:5000/ocp4/openshift4/openshift/release-images` → `4.18.38-x86_64`

---

## Phase 1 — Connected Workstation: Save (Runbook Steps 1-6)

**Objective:** Follow runbook steps 1-6 on the bastion (connected workstation).


| Step | Runbook Step | Action                         | Result                                                                                                                                              | Notes                                                  |
| ---- | ------------ | ------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------ |
| 1.1  | Step 1       | Install fresh ABA              | OK                                                                                                                                                  | Reused existing git clone                              |
| 1.2  | Step 2       | Configure for 4.19.28          | OK                                                                                                                                                  | **Finding:** `--domain` should be `--base-domain`      |
| 1.3  | Step 3       | Add operators                  | OK                                                                                                                                                  | `ops=web-terminal,devworkspace-operator` in `aba.conf` |
| 1.4  | Step 4       | Generate ISC, add 4.18 channel | OK                                                                                                                                                  | `aba -d mirror imagesetconf`, then manual edit         |
| 1.5  | Step 5       | Save images                    | OK — 40 GB tar, 380 release + 10 operator images                                                                                                    | ~35 min                                                |
| 1.6  | Step 6       | Create transfer bundle         | **Issue:** `aba tar --out /tmp/...` failed — `/tmp` on root partition (70 GB) ran out of space. **Workaround:** piped directly via `aba tar --out - | ssh registry 'tar xf - -C ~'`                          |


**Findings:**

1. `**--domain` flag does not exist** — correct flag is `--base-domain`. Runbook updated.
2. **Disk space for bundle creation** — `/tmp` or small root partitions can't hold the bundle. Runbook should note using a path on a partition with sufficient space.

---

## Phase 2 — Disconnected Bastion: Load + Day2 + Upgrade (Runbook Steps 7-13)

**Objective:** Follow runbook steps 7-13 on registry (disconnected bastion).


| Step | Runbook Step | Action                         | Result                                                                                                                 | Notes                                                                          |
| ---- | ------------ | ------------------------------ | ---------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| 2.1  | Step 7       | Extract bundle, install ABA    | OK                                                                                                                     | `./install`                                                                    |
| 2.2  | Step 8       | Register existing Docker :5000 | OK                                                                                                                     | `aba -d mirror register --reg-host ... --ca-cert ... --pull-secret-mirror ...` |
| 2.3  | Step 8b      | Set `reg_path=/ocp/openshift`  | OK                                                                                                                     | Edited `mirror/mirror.conf`                                                    |
| 2.4  | Step 8c      | Verify registry                | OK                                                                                                                     | `aba -d mirror verify` — auth successful                                       |
| 2.5  | Step 9       | Load images                    | OK — images pushed to `/ocp/openshift` path                                                                            | ~10 min                                                                        |
| 2.6  | Step 10      | Create cluster directory       | OK                                                                                                                     | `aba cluster --name sno4 --type sno --starting-ip <ip> --step cluster.conf`    |
| 2.7  | Step 10b     | Place kubeconfig               | OK                                                                                                                     | `mkdir -p sno4/iso-agent-based/auth && cp ...`                                 |
| 2.8  | Step 11      | Authenticate and verify        | OK                                                                                                                     | `. <(aba shell)` + `oc get clusterversion`                                     |
| 2.9  | Step 12      | Run `aba day2`                 | OK — IDMS, ITMS, CatalogSource, CA trust, signatures all applied                                                       | ~5 min                                                                         |
| 2.10 | Step 13      | Trigger upgrade                | **Finding:** `oc adm upgrade --to 4.19.28` fails in disconnected — must use `--to-image` with local digest + `--force` | ~50 min                                                                        |


**Findings:**

1. `**oc adm upgrade --to` fails disconnected** — cannot reach `api.openshift.com` for the update graph. Must use `--to-image=registry:5000/ocp/openshift/openshift/release-images@sha256:<digest> --allow-explicit-upgrade --force`. Runbook updated.
2. `**iso-agent-based/auth/` directory not created by `--step cluster.conf`** — requires manual `mkdir -p`. Enhancement opportunity for ABA.
3. **Control plane briefly unreachable during upgrade** — expected behavior during kube-apiserver and etcd restarts. Monitoring showed "Unable to apply: control plane is down" for ~4 minutes. Self-resolved.

---

## Phase 3 — Post-Upgrade Verification


| Check             | Command                                                      | Result                                                      |
| ----------------- | ------------------------------------------------------------ | ----------------------------------------------------------- |
| Cluster version   | `oc get clusterversion`                                      | **4.19.28**, Available=True, Progressing=False              |
| Node              | `oc get nodes`                                               | sno4 Ready, v1.32.13                                        |
| Cluster operators | `oc get co`                                                  | All 33 at 4.19.28, none Degraded                            |
| IDMS (new)        | `oc get imagedigestmirrorset`                                | `idms-release-0`, `idms-operator-0` present                 |
| IDMS (old)        | `oc get imagedigestmirrorset`                                | `image-digest-mirror` (from original install) still present |
| CatalogSource     | `oc get catalogsource -n openshift-marketplace`              | `redhat-operators` → `registry.example.com`, READY          |
| PackageManifest   | `oc get packagemanifest`                                     | `web-terminal`, `devworkspace-operator` visible             |
| Upgrade history   | `oc get clusterversion -o jsonpath='{..history[*].version}'` | `4.19.28 4.18.38`                                           |


**All checks passed.**

---

## Registry State After Upgrade

```
registry.example.com:5000
├── /ocp4/openshift4/openshift/release-images   → 4.18.38-x86_64 (OLD, untouched)
└── /ocp/openshift/openshift/release-images     → 4.18.38-x86_64, 4.19.28-x86_64 (NEW)
```

Both paths coexist. Old images remain available for rollback if needed.

---

## Runbook Changes Applied


| #   | Change                                                                                                                                                     | Runbook Section                                      | Severity                                                                   |
| --- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------- | -------------------------------------------------------------------------- |
| 1   | `--domain` → `--base-domain`                                                                                                                               | Step 2                                               | **Bug** — command would fail                                               |
| 2   | Use `--to-image` with local digest + `--force` instead of `--to`                                                                                           | Step 13                                              | **Bug** — upgrade would fail in disconnected                               |
| 3   | Show how to get release image digest from local mirror                                                                                                     | Step 13                                              | **Enhancement** — critical for disconnected use                            |
| 4   | Replace all `oc`/`KUBECONFIG` commands with ABA equivalents: `aba run --cmd` for one-off commands, `. <(aba shell)` + raw `oc` for multi-command sequences | Steps 11-13, verification, rollback, troubleshooting | **Enhancement** — dog-fooding, cleaner UX                                  |
| 5   | Note about `iso-agent-based/auth/` dir not auto-created                                                                                                    | Step 10                                              | **Enhancement** — documents current behavior, flags future ABA improvement |
| 6   | Note about bundle disk space on small partitions                                                                                                           | Step 6                                               | **Enhancement** — practical guidance                                       |


---

## Proposed ABA Improvement

`**aba cluster --step cluster.conf` should auto-create `iso-agent-based/auth/`.**

Currently, `aba cluster --name <name> --step cluster.conf` creates the cluster directory and `cluster.conf` but does NOT create `iso-agent-based/auth/`. This directory is only created during the full `install` step. For the upgrade use case (where you're configuring ABA for an *existing* cluster, not installing a new one), users must manually `mkdir -p` before placing their kubeconfig.

**Suggestion:** Have `create-cluster-conf.sh` (or the `cluster.conf` Makefile target) also run `mkdir -p iso-agent-based/auth` so the directory is always present. This is backward-compatible and eliminates the `mkdir -p` step in the runbook.

---

## Timing Summary


| Phase                                             | Duration       |
| ------------------------------------------------- | -------------- |
| Phase 0 — Set up existing environment             | ~1.5 hours     |
| Phase 1 — Connected save (2 releases + operators) | ~1.5 hours     |
| Phase 2 — Transfer + load + day2 + upgrade        | ~1.5 hours     |
| Phase 3 — Verification                            | ~5 minutes     |
| **Total**                                         | **~4.5 hours** |


---

## Conclusion

The runbook workflow is validated end-to-end on x86_64. The core path separation strategy (`/ocp4/openshift4` old vs `/ocp/openshift` new) works correctly. IDMS and existing mirror rules coexist without conflict. The upgrade from 4.18.38 to 4.19.28 completed successfully with all cluster operators healthy.

Two critical bugs were found and fixed (wrong CLI flag, wrong upgrade command for disconnected). The dog-fooding pass replaces all raw `oc`/`KUBECONFIG` usage with ABA's own `aba run --cmd`, `. <(aba shell)`, and `. <(aba login)`.

---

*ABA 1.0.1 | oc-mirror v2 | x86_64 test for s390x runbook | May 2026*