# RUNBOOK: Enable NVIDIA DRA on an Existing Disconnected OpenShift Cluster

> **Reference**: [NVIDIA DRA GPU on OCP](https://docs.nvidia.com/datacenter/cloud-native/openshift/latest/dra-gpu-ocp.html)
> **Scope**: GPU Operator v26.7+ and OpenShift 4.21+ already installed on the disconnected side
> **Verified disconnected**: All steps tested in fully air-gapped environment (no internet)

## What this document covers

You already have:
- ✅ OpenShift 4.21+ cluster running (disconnected)
- ✅ Mirror registry with images loaded
- ✅ GPU Operator v26.7+ installed (from mirrored certified catalog)
- ✅ NFD operator installed
- ✅ IDMS entries applied (`aba day2` was run)

You need to:
- Enable DRA by creating `GPUCluster` and `NVIDIADriver` custom resources

## No image transfer required

**All DRA images are already in your mirror registry.** The GPU Operator
v26.7 CSV declares 20 `relatedImages`, including the DRA driver:

```
nvidia-dra-driver-image  →  nvcr.io/nvidia/dra-driver-nvidia-gpu:v0.5.1
```

When the GPU operator was mirrored (via `oc-mirror` / `aba save` / `aba load`),
all 20 relatedImages were automatically included. The IDMS entries redirect
`nvcr.io/nvidia/*` to your mirror at pull time. **Nothing to download,
transfer, or load.**

---

## Prerequisites check

```bash
# Log into the cluster
export KUBECONFIG=/path/to/kubeconfig
# or: eval $(aba -d <cluster> login)

# 1. Confirm OCP 4.21+
oc get clusterversion -o jsonpath='{.items[0].status.desired.version}'

# 2. Confirm GPU Operator v26.7+ is installed
oc get csv -n nvidia-gpu-operator | grep gpu

# 3. Confirm NFD is running
oc get pods -n openshift-nfd

# 4. Confirm NO ClusterPolicy exists (DRA and ClusterPolicy are mutually exclusive)
oc get clusterpolicy
```

> **If a `ClusterPolicy` exists**: You are using legacy Device Plugin mode.
> You must delete it before enabling DRA:
> ```bash
> oc delete clusterpolicy --all
> ```
> Wait for all GPU-related DaemonSets to terminate before proceeding.

---

## Step 1 — Create the GPUCluster instance

Extract the default CR from the installed CSV and apply it:

```bash
# Find the installed CSV name
GPU_CSV=$(oc get csv -n nvidia-gpu-operator -o name | grep gpu | head -1 \
  | sed 's|clusterserviceversion.operators.coreos.com/||')
echo "GPU CSV: $GPU_CSV"

# Extract the GPUCluster example
oc get csv -n nvidia-gpu-operator $GPU_CSV \
  -o jsonpath='{.metadata.annotations.alm-examples}' | \
  jq -r 'map(select(.kind == "GPUCluster")) | .[0]' > /tmp/gpucluster.json

# Review it
cat /tmp/gpucluster.json

# Apply
oc apply -f /tmp/gpucluster.json
```

This deploys the DRA driver controller and kubelet plugin. The CR
references `nvcr.io/nvidia` — CRI-O redirects to your mirror via IDMS
automatically. No image path changes needed.

---

## Step 2 — Create the NVIDIADriver instance

```bash
# Extract the NVIDIADriver example from the same CSV
oc get csv -n nvidia-gpu-operator $GPU_CSV \
  -o jsonpath='{.metadata.annotations.alm-examples}' | \
  jq -r 'map(select(.kind == "NVIDIADriver")) | .[0]' > /tmp/nvidiadriver.json

# Review it
cat /tmp/nvidiadriver.json

# Apply — no image path changes needed (IDMS handles the redirect)
oc apply -f /tmp/nvidiadriver.json
```

> The CR contains `"repository": "nvcr.io/nvidia"`. This is **not** an
> external reference — CRI-O applies IDMS rules at pull time and
> transparently redirects to your mirror registry.

---

## Step 3 — Verify

```bash
# GPUCluster status (should show "ready")
oc get gpucluster gpu-cluster

# NVIDIADriver status (should show "ready")
oc get nvidiadriver

# DRA controller pod (should be Running)
oc get pods -n nvidia-gpu-operator

# DeviceClass objects (should exist even without GPU hardware)
oc get deviceclass

# ResourceSlices (populated only on nodes with GPUs)
oc get resourceslice

# Confirm no ClusterPolicy (DRA mode, not legacy)
oc get clusterpolicy
```

**Expected results:**

| Component | With GPUs | Without GPUs |
|-----------|-----------|--------------|
| GPUCluster | ready | ready |
| NVIDIADriver | ready | ready |
| DRA controller pod | Running 1/1 | Running 1/1 |
| DeviceClass objects | 5 created | 5 created |
| ResourceSlices | One per GPU node | Empty |
| ClusterPolicy | None | None |

The 5 DeviceClasses created:
- `gpu.nvidia.com`
- `mig.nvidia.com`
- `vfio.gpu.nvidia.com`
- `compute-domain-daemon.nvidia.com`
- `compute-domain-default-channel.nvidia.com`

---

## Step 4 — (Optional) Test with a DRA workload

> Pods will only schedule on nodes with actual NVIDIA GPUs.

```bash
# Create a test project
oc new-project gpu-dra-demo

# Create a ResourceClaimTemplate
cat <<'EOF' | oc create -f -
apiVersion: resource.k8s.io/v1
kind: ResourceClaimTemplate
metadata:
  namespace: gpu-dra-demo
  name: single-gpu
spec:
  spec:
    devices:
      requests:
      - name: gpu
        exactly:
          deviceClassName: gpu.nvidia.com
EOF

# Create a pod that requests a GPU via DRA
cat <<'EOF' | oc create -f -
apiVersion: v1
kind: Pod
metadata:
  namespace: gpu-dra-demo
  name: gpu-pod
spec:
  containers:
  - name: workload
    image: nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda12.5.0-ubi8
    command: ["bash", "-c"]
    args: ["nvidia-smi -L; sleep 9999"]
    resources:
      claims:
      - name: gpu
  resourceClaims:
  - name: gpu
    resourceClaimTemplateName: single-gpu
EOF

# Check status
oc get pod -n gpu-dra-demo gpu-pod
oc get resourceclaim -n gpu-dra-demo

# On a node with a GPU:
# oc exec -n gpu-dra-demo gpu-pod -- nvidia-smi -L

# Clean up
oc delete project gpu-dra-demo
```

> **Note:** The CUDA sample image (`nvcr.io/nvidia/k8s/cuda-sample:...`)
> is NOT included in the GPU operator's relatedImages. If you need it in
> the disconnected environment, add it before mirroring:
> ```bash
> aba image add nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda12.5.0-ubi8
> aba -d mirror save    # then transfer and load
> ```

---

## Uninstall (if needed)

```bash
# Delete workloads first
oc delete resourceclaim --all -A

# Delete CRs
oc delete nvidiadriver --all -n nvidia-gpu-operator
oc delete gpucluster gpu-cluster

# To revert to legacy Device Plugin mode:
# oc create -f /tmp/clusterpolicy.json   (if you have a backup)
```

---

## Troubleshooting

### DRA controller pod not starting / ImagePullBackOff

The IDMS entries for `nvcr.io` are missing. Verify:
```bash
oc get idms -o yaml | grep -B1 "nvcr.io"
```
If no entries, re-run `aba -d <cluster> day2` to apply them.

### GPUCluster stuck in "progressing"

Check the operator logs:
```bash
oc logs -n nvidia-gpu-operator deployment/gpu-operator -f
```

### "ClusterPolicy already exists" error

DRA (`GPUCluster`) and Device Plugin (`ClusterPolicy`) are mutually
exclusive. Delete the ClusterPolicy first:
```bash
oc get clusterpolicy
oc delete clusterpolicy --all
```

### No DeviceClass objects after creating GPUCluster

The GPU operator may need a moment. Wait 60 seconds and re-check.
If still missing, check the DRA controller logs:
```bash
oc logs -n nvidia-gpu-operator deployment/nvidia-dra-driver-controller
```
