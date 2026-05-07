# Runbook Execution Report — OCP 4.18.2 → 4.19.28

**Date:** 2 May 2026 | **Arch:** x86_64 | **Hosts:** registry4 (connected), registry (bastion)

## Test Environment


| Host      | Role                  | CPU                             | vCPU | RAM    | Platform    |
| --------- | --------------------- | ------------------------------- | ---- | ------ | ----------- |
| registry4 | Connected workstation | Intel Xeon Gold 6122 @ 1.80 GHz | 4    | 7.5 GB | VMware ESXi |
| registry  | Disconnected bastion  | Intel Xeon Gold 6122 @ 1.80 GHz | 4    | 7.5 GB | VMware ESXi |
| sno4      | OCP SNO cluster node  | Intel Xeon Gold 6122 @ 1.80 GHz | 10   | 20 GB  | VMware ESXi |


## Pre-setup

Installed OCP 4.18.2 SNO on `registry` using ABA's `platform=vmw` feature, then moved `~/aba` and `~/.aba` aside to simulate a clean customer environment.

## Commands Executed

### Step 1 — Install ABA [registry4] — ~1 min

```
bash -c "$(gitrepo=sjbylo/aba; gitbranch=main; curl -fsSL \
  https://raw.githubusercontent.com/$gitrepo/refs/heads/$gitbranch/install)"
```

### Step 2 — Configure ABA [registry4] — < 1 min

```
aba --channel stable --version 4.19 --platform bm
aba --base-domain example.com \
    --machine-network 10.0.0.0/20 \
    --dns 10.0.1.8 \
    --ntp 10.0.1.8
```

### Step 3 — Select operators [registry4] — < 1 min

```
# Edit aba.conf:
ops=web-terminal,devworkspace-operator
```

### Step 4 — Generate and edit ISC [registry4] — ~1 min

```
aba -d mirror imagesetconf
vi mirror/data/imageset-config.yaml    # set minVersion/maxVersion/shortestPath
```

ISC channels block used:

```yaml
    channels:
    - name: stable-4.19
      minVersion: "4.18.2"
      maxVersion: "4.19.28"
      type: ocp
      shortestPath: true
    graph: true
```

### Step 5 — Save images [registry4] — ~45 min

```
aba -d mirror save
```

Result: `mirror/data/mirror_000001.tar` — 42 GB

### Step 6 — Create bundle [registry4] — 5 min

```
aba tar --out /tmp/aba_upgrade_4.19
```

### Step 7 — Transfer and extract [registry] — 14 min

```
scp /tmp/aba_upgrade_4.19.tar registry:/tmp/       # 6 min (42 GB)
tar xf /tmp/aba_upgrade_4.19.tar                   # 8 min
cd aba && ./install
```

### Step 8 — Register existing Docker registry [registry] — < 1 min

```
aba -d mirror register \
    --reg-host registry.example.com \
    --reg-port 5000 \
    --reg-path /ocp/openshift \
    --pull-secret-mirror ~/.aba-pre-setup/mirror/mirror/pull-secret-mirror.json \
    --ca-cert ~/.aba-pre-setup/mirror/mirror/rootCA.pem
aba -d mirror verify
```

### Step 9 — Load images [registry] — 12 min

```
aba -d mirror load
skopeo list-tags docker://registry.example.com:5000/ocp/openshift/openshift/release-images
```

Result: tags `4.18.2-x86_64`, `4.18.38-x86_64`, `4.19.28-x86_64`

### Step 10 — Create cluster directory [registry] — < 1 min

```
aba cluster --name sno4 --type sno --starting-ip 10.0.1.204 --step cluster.conf
mkdir -p sno4/iso-agent-based/auth
cp ~/aba-pre-setup/sno4/iso-agent-based/auth/kubeconfig sno4/iso-agent-based/auth/kubeconfig
```

### Step 11 — Authenticate and back up [registry] — < 1 min

```
export KUBECONFIG=$PWD/sno4/iso-agent-based/auth/kubeconfig
oc get clusterversion
oc get imagecontentsourcepolicy -o yaml > /tmp/icsp-backup.yaml
oc get imagedigestmirrorset -o yaml > /tmp/idms-backup.yaml
oc get catalogsource -A -o yaml > /tmp/cs-backup.yaml
```

### Step 12 — Run day2 [registry] — 1.5 min

```
aba -d sno4 day2
oc get imagedigestmirrorset
oc get catalogsource -n openshift-marketplace
```

### Step 13 — Trigger upgrade [registry] — ~50 min

```
ARCH=$(uname -m)
release_digest=$(oc adm release info \
  registry.example.com:5000/ocp/openshift/openshift/release-images:4.19.28-$ARCH \
  -o jsonpath='{.digest}')

oc adm upgrade \
  --to-image=registry.example.com:5000/ocp/openshift/openshift/release-images@$release_digest \
  --allow-explicit-upgrade --force
```

### Post-upgrade verification — < 1 min

```
oc get clusterversion                    # 4.19.28, Available=True
oc get co                                # 34/34 Available, 0 Degraded
oc get nodes                             # sno4 Ready
oc get catalogsource -A                  # redhat-operators ready
oc get imagedigestmirrorset              # 3 IDMS present
```

### Operator install test — 2 min

```
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: web-terminal
  namespace: openshift-operators
spec:
  channel: fast
  name: web-terminal
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

oc get csv -n openshift-operators        # web-terminal Succeeded, devworkspace Succeeded
```

## Timing Summary


| Step | Description                | Time            |
| ---- | -------------------------- | --------------- |
| 5    | Save images (42 GB)        | ~45 min         |
| 6    | Create bundle              | 5 min           |
| 7    | Transfer + extract         | 14 min          |
| 9    | Load images                | 12 min          |
| 12   | Run day2                   | 1.5 min         |
| 13   | Upgrade (4.18.2 → 4.19.28) | ~50 min         |
|      | Operator install test      | 2 min           |
|      | **Total**                  | **~2 h 15 min** |


All 13 steps passed. Both mirrored operators installed successfully.