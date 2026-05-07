# DRAFT — Runbook: Upgrade OCP 4.18 → 4.19 and Migrate to ABA / oc-mirror

**Air-Gapped | s390x / LinuxONE**

Upgrade from 4.18.2 to 4.19.x while migrating the mirroring workflow from `oc adm release mirror` to ABA (oc-mirror v2), against an existing Docker v2 registry.


| Current Version | Target Version | Architecture | Workflow                      |
| --------------- | -------------- | ------------ | ----------------------------- |
| 4.18.2          | 4.19.x         | s390x        | 2 hosts (Connected + Bastion) |


---

## Assumptions


| #   | Assumption                                                                                                                                                                                          |
| --- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A1  | OCP 4.18.2 is running on s390x / LinuxONE (`platform: none`).                                                                                                                                       |
| A2  | The existing mirror registry is Docker v2 on port 5000, protected with htpasswd auth and a self-signed TLS certificate.                                                                             |
| A3  | The existing mirror was populated with `oc adm release mirror`. Images reside at a flat path: `registry:5000/ocp4/openshift4`.                                                                      |
| A4  | oc-mirror (via ABA) will write to a SEPARATE path: `registry:5000/ocp/openshift`. Old images are never touched. (See Appendix A.)                                                                   |
| A5  | The cluster has existing ICSP rules from the original install-config.yaml. ABA adds IDMS rules alongside them — both coexist. (See Appendix B.)                                                     |
| A6  | Two-host workflow: a connected workstation (internet access) downloads images; the existing disconnected internal bastion (s390x / LinuxONE) hosts the registry and cluster.                        |
| A7  | You have the registry self-signed CA certificate file and the htpasswd credentials.                                                                                                                 |
| A8  | You have a Red Hat pull secret (console.redhat.com) saved as `~/.pull-secret.json` on the connected workstation.                                                                                    |
| A9  | You have kubeadmin access to the running cluster (password or kubeconfig file).                                                                                                                     |
| A10 | The upgrade path from 4.18.2 → 4.19.x is valid. Verify at [https://access.redhat.com/labs/ocpupgradegraph/update_path](https://access.redhat.com/labs/ocpupgradegraph/update_path) before starting. |


> **Note (s390x boot support):** "Currently, ISO boot support on IBM Z® (s390x) is available only for Red Hat Enterprise Linux (RHEL) KVM, which provides the flexibility to choose either PXE or ISO-based installation. For installations with z/VM and Logical Partition (LPAR), only PXE boot is supported." — [Red Hat documentation](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html-single/installing_an_on-premise_cluster_with_the_agent-based_installer/index#understanding-agent-install_preparing-to-install-with-agent-based-installer)

---

## Disk Space Requirements

Measured values from x86_64 test (May 2026). s390x sizes will differ — use these as a baseline.


| Component                   | Measured (x86) | Notes                                                     |
| --------------------------- | -------------- | --------------------------------------------------------- |
| OCP release (one version)   | 19 GB          | 4.18.38 release images (tar archive)                      |
| OCP releases (4.18 + 4.19)  | ~38 GB         | Both versions, no operators                               |
| 2 small operators           | ~2 GB          | web-terminal + devworkspace-operator                      |
| Total (2 releases + 2 ops)  | 40 GB          | Measured tar: `mirror_000001.tar`                         |
| Per operator (typical)      | 1-5 GB each    | Varies widely; larger operators (e.g. ODF) can be 5+ GB   |
| "ocp" operator set (~8 ops) | ~20-40 GB      | Estimate — web-terminal, nmstate, OADP, descheduler, etc. |
| Total (releases + ocp set)  | ~60-80 GB      | Estimate — tar archive on portable media                  |
| Registry disk after load    | 38 GB          | Measured — both old + new paths in Docker :5000           |


> **Disk needed in three places:**
>
> **(1) Connected workstation** — needs space for both the **oc-mirror cache** (`~/.oc-mirror/.cache/`) AND the **tar archive** (`mirror/data/mirror_*.tar`). The cache is **not cleared** after the tar is created — it persists intentionally so that subsequent mirroring runs only download deltas (new/changed images), and so that a failed save can resume from where it left off. Budget roughly **2x the tar size** (cache ≈ tar). If the cache is manually deleted, the next `aba save` must re-download everything from scratch.
>
> **(2) Portable media** — must hold the tar archive.
>
> **(3) Registry host** — must have free disk for the loaded images.
>
> Budget at least 300-500 GB free on each if using the ocp operator set.

---

## Environment Values

Set these shell variables before starting. They are referenced as `$var` throughout the runbook commands. Substitute your own values.

```bash
export cluster_name=mycluster            # Must match your existing OCP cluster name
export domain=example.com
export machine_network=10.100.3.0/24     # Your cluster's machine network CIDR
export dns_servers=1.2.3.4
export next_hop_address=10.100.3.2
export ntp_servers=198.71.50.75
export reg_host=registry.example.com     # FQDN of your existing Docker registry
export reg_port=5000
export reg_path=/ocp/openshift           # Separate from old /ocp4/openshift4
export ocp_target=4.19.17               # Target version (exact z-release)
```

---

## Network Topology

```
CONNECTED ENVIRONMENT (s390x)
=============================

  +----------------------------+          +---------------------+
  | Connected Workstation      |          | Red Hat Registries  |
  | Fresh RHEL 8/9 host        | <------> | quay.io             |
  | ABA installed (steps 1-6)  |  internet| registry.redhat.io  |
  | Downloads + saves images   |          +---------------------+
  +----------------------------+

                 |
            AIR GAP (portable media)
                 |

DISCONNECTED ENVIRONMENT
========================

  +----------------------------+          +-------------------------+
  | Internal Bastion           |          | OCP 4.18.2 Cluster      |
  | Bundle extracted (steps 7+)|          | platform: none, s390x   |
  |                            |          |                         |
  | +------------------------+ |          |  master01   master02    |
  | | Docker Registry :5000  | | <------> |  master03               |
  | |                        | |  pulls   |  worker01   worker02    |
  | |  /ocp4/openshift4  OLD | |          |                         |
  | |  /ocp/openshift    NEW | |          | ICSP -> /ocp4/openshift4|
  | +------------------------+ |          | IDMS -> /ocp/openshift  |
  +----------------------------+          +-------------------------+
```

The connected workstation downloads images from Red Hat (steps 1-6). The bundle is transferred via portable media across the air gap. The internal bastion loads images into the existing Docker registry (steps 7-9), then configures the cluster (steps 10-13). The cluster pulls from both `/ocp4/openshift4` (old ICSP) and `/ocp/openshift` (new IDMS).

---

## Procedure

### Step 1 — Install ABA on the connected workstation [Connected Workstation]

**Prerequisites:**

- Fresh RHEL 8/9 host with internet access (recommended to avoid cross-contamination).
- `~/.pull-secret.json` exists.

```
bash -c "$(gitrepo=sjbylo/aba; gitbranch=main; curl -fsSL \
  https://raw.githubusercontent.com/$gitrepo/refs/heads/$gitbranch/install)"
cd aba
```

Validate:

```
aba --aba-version
```

---

### Step 2 — Configure ABA for the target version [Connected Workstation]

**Prerequisites:** Step 1 complete. Working directory is `~/aba`.

```bash
aba --channel stable --version ${ocp_target%.*} --platform bm
```

Set network values to match the existing cluster environment:

```bash
aba --base-domain $domain \
    --machine-network $machine_network \
    --dns $dns_servers \
    --ntp $ntp_servers
```

Validate:

```bash
grep -E 'ocp_version|domain|machine_network' aba.conf
```

---

### Step 3 — Select operators [Connected Workstation]

**Prerequisites:** Step 2 complete. `aba.conf` exists.

Example (substitute your own operators):

```bash
# Edit aba.conf:
ops=web-terminal,devworkspace-operator,cincinnati-operator
```

Or use a predefined set:

```bash
aba --op-sets ocp
```

View available sets: `aba --show-op-sets` or `ls templates/operator-set-*`. Dependencies are NOT auto-resolved — include them explicitly (e.g. web-terminal requires devworkspace-operator). The `cincinnati-operator` enables OSUS (see Appendix D).

---

### Step 4 — Generate and edit the ImageSetConfiguration [Connected Workstation]

**Prerequisites:** Steps 2-3 complete. `aba.conf` has correct version and operators.

Generate the ISC file:

```bash
aba -d mirror imagesetconf
```

Edit `mirror/data/imageset-config.yaml` — set a single channel spanning both versions with `shortestPath`:

```yaml
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  platform:
    architectures:
    - s390x
    channels:
    - name: stable-4.19              # target channel includes 4.18.x in its graph
      type: ocp
      minVersion: "4.18.2"           # current running version
      maxVersion: "4.19.17"          # ← your target
      shortestPath: true             # only mirror versions on the shortest upgrade path
    graph: true                      # needed if you want OSUS later (Appendix D)
  operators:
  - catalog: registry.redhat.io/redhat/redhat-operator-index:v4.19
    packages:
    # ... (populated by ABA from ops/op_sets) ...
```

`shortestPath: true` tells oc-mirror to consult the Cincinnati update graph and only download versions on the shortest upgrade path — typically just the source and target versions (e.g. 4.18.2 and 4.19.17), skipping all intermediates. This halves the download size compared to mirroring every version in the range.

See Appendix C: Why mirror both versions and why shortestPath.

---

### Step 5 — Save images to disk [Connected Workstation]

**Prerequisites:**

- Step 4 complete. `imageset-config.yaml` has both versions.
- Disk: see estimates above (35-85 GB depending on operators).

```bash
aba -d mirror save
```

Takes 2-8+ hours depending on network and operator count. Images are cached in `~/.oc-mirror/.cache/` (persists across runs for incremental downloads). Tune in `~/.aba/config` if needed: `OC_MIRROR_IMAGE_TIMEOUT=120m`, `OC_MIRROR_PARALLEL_IMAGES=4`.

Validate:

```bash
ls -lh mirror/data/mirror_*.tar
```

---

### Step 6 — Create transfer bundle [Connected Workstation]

**Prerequisites:** Step 5 complete. `mirror/data/mirror_*.tar` exists.

```
aba tar --out /path/to/portable-media/aba_upgrade_4.19
```

```
cksum /path/to/portable-media/aba_upgrade_4.19.tar \
  | tee /path/to/portable-media/CHECKSUM.txt
```

If too large for media: `aba tar --out - | split -b 10G - /path/to/media/aba_`

---

### Step 7 — Transfer and extract on the internal bastion [Air-gap Transfer]

**Prerequisites:** Step 6 complete. Portable media has the tar + checksum.

```
cksum /path/to/media/aba_upgrade_4.19.tar
# Compare with CHECKSUM.txt
```

```
tar xvf /path/to/media/aba_upgrade_4.19.tar
cd aba
./install
```

Validate:

```
aba --aba-version
```

---

### Step 8 — Register the existing Docker registry with ABA [Internal Bastion]

**Prerequisites:**

- Step 7 complete. ABA installed on the bastion.
- You have: registry CA cert file + htpasswd credentials.
- Registry is running and reachable on port 5000.

```bash
aba -d mirror register \
    --reg-host $reg_host \
    --reg-port $reg_port \
    --reg-path $reg_path \
    --pull-secret-mirror /path/to/pull-secret-mirror.json \
    --ca-cert /mnt/mirror-registry/certs/mirror-registry.crt
```

Validate:

```bash
aba -d mirror verify
```

If you don't have the pull-secret JSON: `aba -d mirror password` (prompts for user/pass).

See Appendix A: Path separation strategy.

---

### Step 9 — Load images into the registry [Internal Bastion]

**Prerequisites:**

- Step 8 complete. `aba -d mirror verify` succeeds.
- Registry host has sufficient free disk (see estimates).

```bash
aba -d mirror load
```

Pushes all images to `$reg_host:$reg_port$reg_path/...` Old images at `/ocp4/openshift4` are untouched.

Validate:

```bash
skopeo list-tags \
  docker://$reg_host:$reg_port$reg_path/openshift/release-images
```

---

### Step 10 — Create an ABA cluster directory [Internal Bastion]

**Prerequisites:** Step 9 complete. Images loaded into registry.

```bash
aba cluster --name $cluster_name --type compact \
    --starting-ip <first-node-ip> \
    --step cluster.conf
```

All parameters (name, type, starting IP, domain, DNS, NTP) must match your running OCP 4.18.2 cluster. This creates the config directory only — it does not install or modify the cluster.

Place your existing kubeconfig so ABA finds it automatically:

```bash
mkdir -p $cluster_name/iso-agent-based/auth
cp /path/to/kubeconfig $cluster_name/iso-agent-based/auth/kubeconfig
```

---

### Step 11 — Authenticate to the cluster and take backups [Internal Bastion]

**Prerequisites:**

- Step 10 complete. Cluster directory exists.
- You have kubeadmin credentials or kubeconfig.

```bash
cd $cluster_name
cp /path/to/kubeconfig iso-agent-based/auth/kubeconfig
. <(aba shell)
```

Validate:

```bash
oc get clusterversion
```

Backup current state (for rollback):

```bash
oc get imagecontentsourcepolicy -o yaml > /tmp/icsp-backup.yaml
oc get imagedigestmirrorset -o yaml > /tmp/idms-backup.yaml
oc get catalogsource -A -o yaml > /tmp/cs-backup.yaml
```

Take an etcd backup before any cluster changes:

```
oc debug node/<master-node> -- chroot /host \
  /usr/local/bin/cluster-backup.sh /home/core/backup
```

---

### Step 12 — Run day2 (OperatorHub + IDMS) [Internal Bastion]

**Prerequisites:** Step 11 complete. `oc whoami` succeeds (via `. <(aba shell)`). Backups taken.

```bash
cd $cluster_name
aba day2
```

Adds mirror CA to cluster trust, applies IDMS/ITMS, disables default catalog sources, creates mirrored CatalogSources, applies release signatures.

Validate:

```bash
. <(aba shell)
oc get imagecontentsourcepolicy   # old ICSP still present
oc get imagedigestmirrorset       # new IDMS added
oc get catalogsource -n openshift-marketplace
oc get packagemanifest | head -20
```

See Appendix B: ICSP + IDMS coexistence.

> **Rollback** (assumes `. <(aba shell)` is active):
>
> ```bash
> oc patch OperatorHub cluster --type json \
>   -p '[{"op":"replace","path":"/spec/disableAllDefaultSources","value":false}]'
> oc get idms -o name | xargs oc delete
> oc get itms -o name | xargs oc delete
> oc delete catalogsource -n openshift-marketplace \
>   redhat-operators certified-operators community-operators
> oc delete cm registry-config -n openshift-config
> ```

---

### Step 13 — Trigger the OCP upgrade [Internal Bastion]

**Prerequisites:**

- Step 12 complete. OperatorHub functional. etcd backup taken.
- Maintenance window in effect.

Get the release image digest from the local mirror:

```bash
. <(aba shell)
ARCH=$(uname -m)   # Release images use raw kernel arch: x86_64, s390x, aarch64, ppc64le
release_digest=$(oc adm release info \
  $reg_host:$reg_port$reg_path/openshift/release-images:$ocp_target-$ARCH \
  -o jsonpath='{.digest}')
echo "Digest: $release_digest"
```

Trigger the upgrade using the digest (disconnected clusters cannot reach the update graph):

```bash
oc adm upgrade \
  --to-image=$reg_host:$reg_port$reg_path/openshift/release-images@$release_digest \
  --allow-explicit-upgrade --force
```

`--force` is required because the disconnected cluster has no update graph to validate against.

Monitor:

```bash
watch oc get clusterversion
oc adm upgrade
oc get co
```

Upgrade takes 30-90 minutes. All cluster operators should reach Available=True, Progressing=False, Degraded=False.

> **Rollback:** OCP does NOT support minor-version downgrade. Recovery requires restoring from the etcd backup taken in step 11.

---

## Post-Upgrade Verification


All commands below assume `. <(aba shell)` is active.

| Check             | Command                              | Expected                     |
| ----------------- | ------------------------------------ | ---------------------------- |
| Cluster version   | `oc get clusterversion`              | 4.19.x, Available=True       |
| Cluster operators | `oc get co`                          | All Available, none Degraded |
| Nodes             | `oc get nodes`                       | All Ready                    |
| OperatorHub       | `oc get catalogsource -A`            | READY state                  |
| ICSP (old)        | `oc get imagecontentsourcepolicy`    | Still present                |
| IDMS (new)        | `oc get imagedigestmirrorset`        | Present                      |


---

## Post-Upgrade: Optional Cleanup

### Remove old ICSP rules

After the upgrade is stable, you can remove the old ICSP. The IDMS now covers both 4.18.2 and 4.19.x at `$reg_path`. Old images at `/ocp4/openshift4` become unused.

All commands below assume `. <(aba shell)` is active.

```bash
oc get imagecontentsourcepolicy
oc delete imagecontentsourcepolicy <name>
oc get events --field-selector reason=Failed -A | grep -i image
```

If pulls fail after removal: `oc apply -f /tmp/icsp-backup.yaml`

### Purge old images from the registry (optional)

Once the old ICSP is removed and the cluster is confirmed healthy on the new IDMS paths, the old images at `/ocp4/openshift4` are no longer needed. You can reclaim disk space by deleting them from the Docker registry.

> **WARNING: Point of no return.** Only do this after thorough verification. If anything still references `/ocp4/openshift4`, those pulls will fail. Ensure the old ICSP has been removed and no image pull errors exist before proceeding.

The Docker v2 registry stores blobs on disk. To remove the old repository path:

```bash
# 1. Find the registry storage root from the container's volume mount
REG_CONTAINER=$(podman ps --format '{{.Names}}' | grep -i registry | head -1)
podman inspect $REG_CONTAINER --format '{{range .Mounts}}{{.Source}} {{end}}'
#    e.g. /mnt/mirror-registry/data

REPO_ROOT=/mnt/mirror-registry/data/docker/registry/v2/repositories

# 2. Verify the old path exists
du -sh $REPO_ROOT/ocp4
ls $REPO_ROOT/ocp4/openshift4

# 3. Remove the old repository metadata
rm -rf $REPO_ROOT/ocp4

# 4. Find the config file inside the container and run garbage collection
podman exec $REG_CONTAINER find /etc -name 'config.yml' 2>/dev/null
#    Typically: /etc/distribution/config.yml or /etc/docker/registry/config.yml
podman exec $REG_CONTAINER registry garbage-collect /etc/distribution/config.yml

# 5. Verify disk space reclaimed
df -h
```

Step 4 is critical — deleting the repository directory only removes metadata (manifests, tags). The actual image layers (blobs) are shared and only freed by garbage collection. The config file path varies by container image; use the `find` command above to locate it.

---

## Appendices

### A. Path Separation Strategy

The existing registry was populated with `oc adm release mirror` (OpenShift-Z scripts), which stores images flat under `registry:5000/ocp4/openshift4`. ABA uses oc-mirror v2, which creates subdirectories (`.../openshift/release-images`, `.../openshift/release`).

Rather than mixing both tools' output under the same base path, we configure ABA with a separate `reg_path` (`/ocp/openshift`). This is version-neutral — the same path works for OCP 4.x, 5.x, and beyond. Layout:

```
Docker Registry :5000
├── /ocp4/openshift4              ← OLD (oc adm release mirror, untouched)
│   └── :4.18.2-s390x, @sha256:...
│
└── /ocp/openshift                ← NEW (oc-mirror via ABA)
    ├── openshift/release-images  ← 4.18.2 + 4.19.x (and future 5.x) release images
    ├── openshift/release         ← component images
    └── (operators)/...           ← operator images
```

No overlap, no ambiguity. The path is version-neutral: when upgrading from OCP 4 to 5, keep using `/ocp/openshift` and add 5.x channels to the ISC. If you ever need to clean up, delete `/ocp/openshift` without affecting the original images.

### B. ICSP + IDMS Coexistence

The original cluster `install-config.yaml` created ICSP (ImageContentSourcePolicy) rules that redirect image pulls from `quay.io/openshift-release-dev/*` to `registry:5000/ocp4/openshift4`.

ABA's `day2` command applies IDMS (ImageDigestMirrorSet) rules — the modern replacement — that redirect to `registry:5000/ocp/openshift/openshift/release-images` and related paths.

Both ICSP and IDMS are evaluated simultaneously by CRI-O on the cluster nodes. When a pod requests an image (e.g. `quay.io/openshift-release-dev/ocp-release@sha256:abc...`), CRI-O merges all matching mirror rules and tries each mirror in order until the image is found. The old ICSP resolves existing 4.18 images from the flat path; the new IDMS resolves 4.19 (and operator) images from the oc-mirror paths. No conflict.

After the upgrade, you can optionally remove the old ICSP (since the IDMS covers both versions). This is a cleanup step, not a requirement.

### C. Why Mirror Both Versions — and Why shortestPath

oc-mirror save creates a self-contained archive. The 4.18.2 images must be included because:

1. oc-mirror pushes to different subpaths than `oc adm release mirror`. The cluster may reference 4.18 images via the new IDMS during the upgrade — they must exist at the oc-mirror paths too.
2. If you later remove the old ICSP, ALL images (4.18 + 4.19) must be reachable via the IDMS paths. Having 4.18 at the oc-mirror path makes this safe.
3. Some 4.18 component images may be pulled during the transition window while nodes are running mixed versions.

**Why a single channel works:** The `stable-4.19` channel's update graph includes all 4.18.x versions as valid starting points (verified: 4.18.1 through 4.18.20+ are listed). Specifying `minVersion: "4.18.2"` within `stable-4.19` is therefore valid.

**Why `shortestPath: true`:** Without it, oc-mirror downloads *every* version between `minVersion` and `maxVersion` in the graph — potentially dozens of intermediate 4.18.z and 4.19.z releases. With `shortestPath: true`, oc-mirror consults the Cincinnati graph and only mirrors the versions on the shortest upgrade path. Tested result: 381 images (2 versions) vs 760 images (4 versions) without it — half the download, disk, and transfer time.

**Two-channel alternative:** If your current version is very old and not present in the target channel's graph, you may need two separate channel entries (one for each minor). The single-channel approach was tested and confirmed working for 4.18.2 → 4.19.28.

### D. Optional: OpenShift Update Service (OSUS)

OSUS provides an in-cluster update graph so upgrade paths appear in the web console. Entirely optional.

**Prerequisites:**

- `cincinnati-operator` included in `ops` (`aba.conf`, before step 5)
- `graph: true` in the ImageSetConfiguration (already set in step 4)
- `aba day2` already run (step 12)
- `cincinnati-operator` installed via OperatorHub

**Procedure:**

```bash
cd $cluster_name
aba day2-osus
```

> **Rollback** (assumes `. <(aba shell)` is active):
>
> ```bash
> oc delete updateservice -n openshift-update-service --all
> oc delete subscription cincinnati-operator -n openshift-update-service
> oc delete csv -n openshift-update-service --all
> oc delete operatorgroup -n openshift-update-service --all
> oc delete namespace openshift-update-service
> oc patch clusterversion version --type merge -p '{"spec":{"upstream":""}}'
> ```

### E. Troubleshooting


| Problem                                  | Fix                                                                                                                                     |
| ---------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| oc-mirror save times out                 | Set `OC_MIRROR_IMAGE_TIMEOUT=120m` and `OC_MIRROR_PARALLEL_IMAGES=4` in `~/.aba/config`                                                 |
| aba day2 cannot access the cluster       | Run `. <(aba shell)` or `. <(aba login)` first. Or place kubeconfig at `$cluster_name/iso-agent-based/auth/kubeconfig`.                 |
| aba load fails: network unreachable      | `aba -d mirror clean`, then retry `aba -d mirror load`                                                                                  |
| CatalogSource stuck in TRANSIENT_FAILURE | Usually resolves in minutes. Check: `. <(aba shell)` then `oc get pods -n openshift-marketplace`. Ensure port $reg_port accessible from all nodes. |
| Image pulls fail after ICSP removal      | Restore: `. <(aba shell)` then `oc apply -f /tmp/icsp-backup.yaml`                                                                      |


### F. Alternative: New Quay Registry

If you prefer stronger isolation, install a new Quay registry on a different port (e.g. :8443) or host. Replace `aba -d mirror register` (step 8) with `aba -d mirror install --vendor quay`. The old Docker registry remains untouched as a fallback. Uses more disk but provides stronger rollback guarantees.

---

*ABA 1.0.x | oc-mirror v2 | s390x / LinuxONE | May 2026*
