# Troubleshooting

**Contents**

- [Quay mirror registry](#quay-mirror-registry)
- [oc-mirror disk space](#oc-mirror-disk-space)
- [Cluster install: bootstrap failure](#cluster-install-bootstrap-failure)
- [Cluster install: stalled or not progressing](#cluster-install-stalled-or-not-progressing)
- [Cluster install: debugging the rendezvous node](#cluster-install-debugging-the-rendezvous-node)
- [MAC address reuse issues](#mac-address-reuse-issues)
- [vSphere Preflight Validation](#vsphere-preflight-validation)

> See also the [Troubleshooting FAQ](README.md#troubleshooting) in the README for additional topics (Quay sync failures, `oc-mirror` cache issues, network unreachable errors, bastion network mismatch, and more).

---

## Quay mirror registry

If you see the error "Cannot initialize user in a non-empty database" when trying to install Quay, this usually means that Quay files from a previous installation still exist and should be deleted. Delete any old files from `~/quay-install` and try again.

---

## oc-mirror disk space

Sometimes `oc-mirror` runs out of temporary disk space under `/tmp`. Fix this by increasing the space under `/tmp` or setting `data_dir` in `mirror/mirror.conf` to a directory with more disk space:

```
sudo mount -o remount,size=6G /tmp
```

See also: https://access.redhat.com/solutions/2843

---

## Cluster install: bootstrap failure

The installation may fail with an error similar to:

```
ERROR Bootstrap failed to complete: : bootstrap process timed out: context deadline exceeded
```

You might also see the following errors:

```
INFO Unable to retrieve cluster metadata from Agent Rest API: [GET /v2/clusters/{cluster_id}][404] v2GetClusterNotFound  &{Code:0xc0000b3c30 Href:0xc0000b3c40 ID:0xc000f06cec Kind:0xc0000b3c50 Reason:0xc0000b3c60}
INFO Unable to retrieve cluster metadata from Agent Rest API: [GET /v2/clusters/{cluster_id}][404] v2GetClusterNotFound  &{Code:0xc000f855c0 Href:0xc000f855d0 ID:0xc000e80e5c Kind:0xc000f855e0 Reason:0xc000f855f0}
ERROR Attempted to gather ClusterOperator status after wait failure: Listing ClusterOperator objects: Get "https://api.compact.example.com:6443/apis/config.openshift.io/v1/clusteroperators": tls: failed to verify certificate: x509: certificate is valid for kubernetes, kubernetes.default, kubernetes.default.svc, kubernetes.default.svc.cluster.local, openshift, openshift.default, openshift.default.svc, openshift.default.svc.cluster.local, 172.30.0.1, not api.compact.example.com
INFO Use the following commands to gather logs from the cluster
INFO openshift-install gather bootstrap --help
ERROR Bootstrap failed to complete: : bootstrap process timed out: context deadline exceeded
```

**What to check:**

1. SSH to the rendezvous node to investigate:
   ```
   aba -d mycluster ssh
   ```
   If SSH fails, access the server's console directly.

2. After fixing the problem, you may need to regenerate agent configuration files, the ISO, or both. Run `aba -d mycluster clean` and then `aba -d mycluster install` to start again.

3. When reinstalling a cluster, use `aba -d mycluster clean` (not `aba -d mycluster refresh`) to generate fresh random MAC addresses — see [MAC address reuse issues](#mac-address-reuse-issues) below.

---

## Cluster install: stalled or not progressing

If the installation appears stuck — cluster operators remain `Degraded` or `Progressing` for an extended period, or pods are crashlooping — try:

```
aba -d mycluster unstick
```

This finds pods that have been not-ready for more than 5 minutes (crashlooping, stuck in `ContainerCreating`, `ImagePullBackOff`, `Error`, etc.) and deletes them so Kubernetes reschedules fresh replacements. Critical static pods (`etcd`, `kube-apiserver`) are never touched. It is safe to run multiple times on a non-progressing cluster install.

**Common examples of stuck pods during installation:**

- `openshift-ingress-canary/ingress-canary-*` — stuck in `ContainerCreating`, blocks the Ingress operator from reporting `Available`.
- `openshift-network-diagnostics/network-check-target-*` — crashlooping, causes the Network operator to report `Degraded`.
- `openshift-dns/dns-default-*` — not ready, prevents DNS resolution for other pods and cascades failures.
- `openshift-console/console-*` — crashlooping, blocks the Console operator.
- `openshift-authentication/oauth-openshift-*` — stuck, prevents login and causes Authentication operator degradation.
- `openshift-ingress/router-default-*` — not ready, blocks the Ingress operator.

These are typically transient — a pod races with a dependency that isn't ready yet and gets stuck. Deleting the pod lets Kubernetes retry with the dependency now available.

If the cluster still does not recover after running `unstick`, check `aba -d mycluster mon` output and SSH to the nodes (`aba -d mycluster ssh`) for further investigation.

---

## Cluster install: debugging the rendezvous node

SSH to the rendezvous node to investigate installation problems:

```
aba -d mycluster ssh
# This will run `ssh core@<ip of rendezvous server>`
```

### Check the Assisted Service

The Assisted Service must be able to pull its image and start:

```
[core@master1 ~]$ journalctl -u assisted-service.service -f
Nov 19 02:14:31 master1 systemd[1]: Starting Assisted Service container...
Nov 19 02:14:31 master1 podman[2600]: Trying to pull quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:042248d2950dab0cb12163bfa021ce5c980b828feeb33080eec24accd5fb8adc...
Nov 19 02:14:31 master1 podman[2600]: Getting image source signatures
Nov 19 02:14:31 master1 podman[2600]: Copying blob sha256:516e4391bf00c004b3f333b2f8649982ce9dbb7f0e30405b5c10bf67b7c573bc
Nov 19 02:14:31 master1 podman[2600]: Copying blob sha256:97da74cc6d8fa5d1634eb1760fd1da5c6048619c264c23e62d75f3bf6b8ef5c4
Nov 19 02:14:31 master1 podman[2600]: Copying blob sha256:225bb0746beb8f28f6f4fadfba9a75debd4628e3c9c95956eca922f82f956d9b
Nov 19 02:14:31 master1 podman[2600]: Copying blob sha256:d8190195889efb5333eeec18af9b6c82313edd4db62989bd3a357caca4f13f0e
Nov 19 02:14:31 master1 podman[2600]: Copying blob sha256:43e3075e6dc816f272ecb9a69965e9e05b2938bfada8eec974e6ab4ab9de65f3
...

Started Assisted Service container
```

If it fails, the log will show:

```
Nov 23 09:31:53 master1 systemd[1]: Starting Assisted Service container...
Nov 23 09:31:53 master1 podman[2424]: Trying to pull quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:d28c9adc6863eb1d3983d15f5da41a91d39bc7c5493092006f95d7acd2463fe6...
Nov 23 09:31:56 master1 podman[2424]: Error: initializing source docker://quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:d28c9adc6863eb1d3983d15f5da41a91d39bc7c5493092006f95d7acd2463fe6: reading manifest sha256:d28c9adc6863eb1d3983d15f5da41a91d39bc7c5493092006f95d7acd2463fe6 in quay.io/openshift-release-dev/ocp-v4.0-art-dev: unauthorized: access to the requested resource is not authorized
Nov 23 09:31:56 master1 systemd[1]: assisted-service.service: Main process exited, code=exited, status=125/n/a
Nov 23 09:31:56 master1 systemd[1]: Dependency failed for Assisted Service container.
Nov 23 09:31:56 master1 systemd[1]: assisted-service.service: Job assisted-service.service/start failed with result 'dependency'.
Nov 23 09:31:56 master1 systemd[1]: assisted-service.service: Failed with result 'exit-code'.
Nov 23 09:31:56 master1 systemd[1]: assisted-service.service: Scheduled restart job, restart counter is at 1.
Nov 23 09:31:56 master1 systemd[1]: Stopped Assisted Service container.
```

- Check the pull-secret, the root CA cert, the registry hostname and port in `mirror.conf` and `cluster.conf`.
- Verify mirror access: `aba -d mirror verify`

### Check that InfraEnv registered

Look for:

```
Successfully registered InfraEnv ocp1 with id
```

### Check the release image download

```
[core@master1 ~]$ journalctl -b -u release-image.service -f
Nov 19 02:18:18 master1 systemd[1]: Starting Download the OpenShift Release Image...
Nov 19 02:18:18 master1 release-image-download.sh[5747]: Pulling quay.io/openshift-release-dev/ocp-release@sha256:f8ba6f54eae419aba17926417d950ae18e06021beae9d7947a8b8243ad48353a...
Nov 19 02:18:18 master1 release-image-download.sh[5853]: 0adedea0b5eac1a9f85b61c904bd73060cea4718dae98ee1fb8a3af444067a0d
Nov 19 02:18:19 master1 systemd[1]: Finished Download the OpenShift Release Image.
```

### Monitor bootkube progress

```
[core@master1 ~]$ journalctl -b -u bootkube.service -f
```

It is normal to see warnings and errors during bootkube startup:
- "unable to get REST mapping for ..."
- "no matches for kind ..."
- "Failed to create ..."

After 5-10 minutes, you should see pods starting to appear:

```
Nov 19 02:27:06 master1 bootkube.sh[10004]:         Pod Status:openshift-kube-scheduler/openshift-kube-scheduler        DoesNotExist
Nov 19 02:27:06 master1 bootkube.sh[10004]:         Pod Status:openshift-kube-controller-manager/kube-controller-manager        DoesNotExist
Nov 19 02:27:06 master1 bootkube.sh[10004]:         Pod Status:openshift-cluster-version/cluster-version-operator        Pending
Nov 19 02:27:06 master1 bootkube.sh[10004]:         Pod Status:openshift-kube-apiserver/kube-apiserver        DoesNotExist
```

Then progressing:

```
Nov 19 02:38:46 master1 bootkube.sh[10004]:         Pod Status:openshift-kube-apiserver/kube-apiserver        Pending
Nov 19 02:38:46 master1 bootkube.sh[10004]:         Pod Status:openshift-kube-scheduler/openshift-kube-scheduler        RunningNotReady
Nov 19 02:38:46 master1 bootkube.sh[10004]:         Pod Status:openshift-kube-controller-manager/kube-controller-manager        DoesNotExist
Nov 19 02:38:46 master1 bootkube.sh[10004]:         Pod Status:openshift-cluster-version/cluster-version-operator        Ready
```

All pods ready:

```
Nov 19 02:39:21 master1 bootkube.sh[10004]:         Pod Status:openshift-kube-apiserver/kube-apiserver        Ready
Nov 19 02:39:21 master1 bootkube.sh[10004]:         Pod Status:openshift-kube-scheduler/openshift-kube-scheduler        Ready
Nov 19 02:39:21 master1 bootkube.sh[10004]:         Pod Status:openshift-kube-controller-manager/kube-controller-manager        Ready
Nov 19 02:39:21 master1 bootkube.sh[10004]:         Pod Status:openshift-cluster-version/cluster-version-operator        Ready
```

Followed by masters joining and bootkube completing:

```
Nov 19 02:39:21 master1 bootkube.sh[10004]: All self-hosted control plane components successfully started
Nov 19 02:39:21 master1 bootkube.sh[10004]: Waiting for 2 masters to join        0 masters joined the cluster
Nov 19 02:39:26 master1 bootkube.sh[10004]:         Master master2 joined the cluster
Nov 19 02:39:26 master1 bootkube.sh[10004]:         Master master3 joined the cluster
Nov 19 02:39:26 master1 bootkube.sh[10004]:         2 masters joined the cluster
Nov 19 02:39:26 master1 bootkube.sh[10004]: All self-hosted control plane components successfully started
Nov 19 02:39:26 master1 bootkube.sh[10004]: Sending bootstrap-success event. Waiting for remaining assets to be created.
```

### Monitor cluster operators after bootstrap

Once bootkube completes and the node restarts:

```
aba -d mycluster run --cmd "get co"
aba -d mycluster run --cmd "get nodes"
```

---

## MAC address reuse issues

Repeated installation of OpenShift using the exact same MAC addresses can cause the install to fail or take a long time to complete.

When reinstalling a cluster, run `aba -d mycluster clean` first (not `aba -d mycluster refresh`). This regenerates the configuration with fresh random MAC addresses, as long as `xx` is present in the `mac_prefix` parameter in `cluster.conf`.

---

## vSphere Preflight Validation

Before generating the ISO, ABA runs a vSphere preflight check (when
`platform=vmw` in `aba.conf`) that verifies connectivity, TLS trust,
credentials, resource existence, and per-scope privilege grants. On failure,
preflight aborts before `openshift-install` is invoked and the ISO file
(`iso-agent-based/agent.$(arch).iso`) is NOT produced. Every preflight output
line starts with the token `vSphere:` for greppability.

### ESXi vs vCenter

`normalize-vmware-conf` keys off the `API type` reported by `govc about`. On a
standalone ESXi host (`API type: HostAgent`), `GOVC_DATACENTER` and
`GOVC_CLUSTER` are optional - the synthetic `/ha-datacenter` is always
present, ESXi has no clusters, and ESXi auth is typically as root with
implicit full privileges. The preflight runs a reduced probe set:

- Layer 1 (TCP / TLS / auth) - same as vCenter.
- Layer 2 - datastore and network resolved under `/ha-datacenter/datastore`
  and `/ha-datacenter/network`. `VC_FOLDER` is probed if set; if unset, an
  info note is emitted and the installer creates the folder on first use.
- Layer 3 (cluster + network-on-cluster attach + resource pool) - skipped.
- Layer 4 (vCenter-style privilege scopes) - skipped.

The success banner tells you which path ran:

```
vSphere: ESXi detected (reduced preflight: TCP+TLS+auth+datastore+network)
vSphere: vCenter detected, running checks...
```

### For operators: reading the output

Example failing output:

```
vSphere: datastore '/Datacenter/datastore/fast-ssd' missing privilege 'Datastore.AllocateSpace'
vSphere: folder '/Datacenter/vm/aba-test' missing privilege 'Resource.AssignVMToPool'
vSphere: 2 privilege gap(s) across 2 scope(s)
```

Line-by-line:

- `vSphere: ... missing privilege 'X'` - the vCenter user has a role assigned
  on that specific vSphere object, but the role does not grant privilege `X`.
  Ask your vSphere admin to grant it (or bind a role that does) - see the
  admin subsection below for a worked example.
- `vSphere: ... not found` - the named vSphere object does not exist at the
  stated path. This is a **configuration** problem, not an RBAC problem:
  check the spelling of `GOVC_DATACENTER`, `GOVC_CLUSTER`, `GOVC_DATASTORE`,
  `GOVC_NETWORK`, `VC_FOLDER`, and `GOVC_RESOURCE_POOL` in your
  `vmware.conf`. "Privilege not granted" and "object not found" are
  **never** conflated by preflight - the wording tells you which class of
  problem to fix.
- `vSphere: cannot verify write-access on '...'` (warning) - the user lacks
  permission to even READ the permission list on that object, typically
  because the user is missing `System.Read`. The query gap is reported as a
  warning (not counted as an error) because subsequent scope checks may
  still catch actionable privilege gaps. To fix this warning specifically,
  grant `System.Read` on the object.
- `vSphere: N privilege gap(s) across M scope(s)` - the summary line that
  appears only when at least one privilege gap was recorded. N is the total
  gap count; M is the number of distinct vSphere scopes (root, datacenter,
  cluster, datastore, network, folder, resource pool) where at least one
  gap was observed.

After fixing the RBAC or the configuration, re-run `aba -d mycluster install`. No extra
flag is needed - preflight runs automatically on every install attempt.

### ESXi: "Network not found" on a freshly installed host

On a freshly installed standalone ESXi host, `govc vm.create` (and
`govc find / -type Network`) may fail to find port groups that clearly
exist in the ESXi UI and via `esxcli network vswitch standard portgroup
list`. This has been observed with the default "VM Network" port group
on ESXi 7.0.3 after a fresh install — the port group was not visible
in the vSphere Managed Object Browser (MOB), which `govc` relies on.
The exact root cause is not fully understood; it may be related to how
or when the port group was created during installation. Port groups
created via the **ESXi web UI** were visible to `govc` on the same host.

Previously vCenter-managed hosts were not affected in our testing.

**Workaround:** In the ESXi web UI (Networking > Port groups), create a
new port group on the same vSwitch (e.g. "VM Network 2") and use that
name in `vmware.conf` (`GOVC_NETWORK`). The new port group will be on
the same physical network (same vSwitch, same uplink) and will be
visible to `govc`.

**Permanent fix:** To reclaim the original name, power off all VMs,
move the VMkernel NIC (`vmk0`) to a temporary port group, delete the
installer-created "VM Network", recreate "VM Network" via the web UI,
move `vmk0` back, then power VMs on. The recreated port group will be
MOB-registered.

The full curated list of privileges preflight expects is in
[scripts/vmware-required-privileges.sh](scripts/vmware-required-privileges.sh).
Hand this file to your vSphere admin if you do not have admin rights
yourself; the file header links to the upstream OpenShift documentation
section it derives from.

### For vSphere admins: granting the privileges

The curated privilege list lives in
[scripts/vmware-required-privileges.sh](scripts/vmware-required-privileges.sh)
as one bash array per vSphere scope (root, datacenter, cluster, datastore,
network, folder, resource pool). The file's header links to the upstream
OpenShift documentation section it derives from.

To create a role that holds every required privilege across every scope and
bind it to a vCenter user, use `govc`:

    # Source the curated arrays
    source scripts/vmware-required-privileges.sh

    # Create an "aba-installer" role holding the union of all required
    # privileges (govc role.create takes a role name followed by privilege
    # strings; the "${ARRAY[@]}" expansion passes each element as a
    # separate argument).
    govc role.create aba-installer \
        "${VSPHERE_PRIVS_ROOT[@]}" \
        "${VSPHERE_PRIVS_DATACENTER[@]}" \
        "${VSPHERE_PRIVS_CLUSTER[@]}" \
        "${VSPHERE_PRIVS_DATASTORE[@]}" \
        "${VSPHERE_PRIVS_NETWORK[@]}" \
        "${VSPHERE_PRIVS_FOLDER[@]}" \
        "${VSPHERE_PRIVS_RESOURCE_POOL[@]}"

    # Bind the role to the installer user on each relevant scope. Example
    # for the resource pool scope:
    govc permissions.set \
        -principal installer@vsphere.local \
        -role aba-installer \
        /Datacenter/host/Cluster/Resources

    # Repeat 'govc permissions.set' for each scope the installer needs:
    # the root (/), the datacenter, the cluster, each datastore, the
    # network/portgroup, and the target VM folder.

Because the `role.create` above expands the arrays at run time, if a new
privilege is ever added to
[scripts/vmware-required-privileges.sh](scripts/vmware-required-privileges.sh)
the admin only needs to re-run the two commands - the updated array is
picked up on the next shell expansion with no script edits.
