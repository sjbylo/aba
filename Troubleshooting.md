# Troubleshooting 

## Quay mirror registry

If you see the error "Cannot initialize user in a non-empty database" when trying to install Quay, this usually means that Quay files - from a previous installation - still exist 
and should be deleted.  Delete any old files from ~/quay-install and try again.

## Booting and Internet connection of the Rendezvous Node

Try these commands to discover any problems with the installation of OpenShift using the Agent-based method.

Ssh to the rendezvous server:
```
aba -d mycluster ssh
# This will run `ssh core@<ip of rendezvous server>`

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

- Be sure the Assisted Service image can be pulled and started.

If it fails the log will show:

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


If the image cannot be pulled from the registry:

```
unauthorized: access to the requested resource is not authorized
```
- Check the pull-secret, the root CA cert, the registry hostname and port in the mirror.conf and cluster.conf files. 
- Run the following to verify mirror access: `aba -d mirror verify`

Be sure the InfraEnv is properly set:

```
Successfully registered InfraEnv ocp1 with id
```

Be sure the release image can be pulled:

```
[core@master1 ~]$   journalctl -b -u release-image.service -f
Nov 19 02:18:18 master1 systemd[1]: Starting Download the OpenShift Release Image...
Nov 19 02:18:18 master1 release-image-download.sh[5747]: Pulling quay.io/openshift-release-dev/ocp-release@sha256:f8ba6f54eae419aba17926417d950ae18e06021beae9d7947a8b8243ad48353a...
Nov 19 02:18:18 master1 release-image-download.sh[5853]: 0adedea0b5eac1a9f85b61c904bd73060cea4718dae98ee1fb8a3af444067a0d
Nov 19 02:18:19 master1 systemd[1]: Finished Download the OpenShift Release Image.
```

During bootkube installation:

```
[core@master1 ~]$   journalctl -b -u bootkube.service -f
```

It is normal to see warnings, errors and failure messages.  

Typical errors:
- "unable to get REST mapping for ..."
- "no matches for kind ..." 
- "Failed to create ..."

But, after 5-10 mins you should see more positive messages:

```
Nov 19 02:27:06 master1 bootkube.sh[10004]:         Pod Status:openshift-kube-scheduler/openshift-kube-scheduler        DoesNotExist
Nov 19 02:27:06 master1 bootkube.sh[10004]:         Pod Status:openshift-kube-controller-manager/kube-controller-manager        DoesNotExist
Nov 19 02:27:06 master1 bootkube.sh[10004]:         Pod Status:openshift-cluster-version/cluster-version-operator        Pending
Nov 19 02:27:06 master1 bootkube.sh[10004]:         Pod Status:openshift-kube-apiserver/kube-apiserver        DoesNotExist
```

Installation progressing:

```
Nov 19 02:38:46 master1 bootkube.sh[10004]:         Pod Status:openshift-kube-apiserver/kube-apiserver        Pending
Nov 19 02:38:46 master1 bootkube.sh[10004]:         Pod Status:openshift-kube-scheduler/openshift-kube-scheduler        RunningNotReady
Nov 19 02:38:46 master1 bootkube.sh[10004]:         Pod Status:openshift-kube-controller-manager/kube-controller-manager        DoesNotExist
Nov 19 02:38:46 master1 bootkube.sh[10004]:         Pod Status:openshift-cluster-version/cluster-version-operator        Ready
```

Installation of bootkube complete:
```
Nov 19 02:39:21 master1 bootkube.sh[10004]:         Pod Status:openshift-kube-apiserver/kube-apiserver        Ready
Nov 19 02:39:21 master1 bootkube.sh[10004]:         Pod Status:openshift-kube-scheduler/openshift-kube-scheduler        Ready
Nov 19 02:39:21 master1 bootkube.sh[10004]:         Pod Status:openshift-kube-controller-manager/kube-controller-manager        Ready
Nov 19 02:39:21 master1 bootkube.sh[10004]:         Pod Status:openshift-cluster-version/cluster-version-operator        Ready
```

... success!

Then, the log will show the following: 

```
Nov 19 02:39:21 master1 bootkube.sh[10004]: All self-hosted control plane components successfully started
Nov 19 02:39:21 master1 bootkube.sh[10004]: Waiting for 2 masters to join        0 masters joined the cluster
Nov 19 02:39:26 master1 bootkube.sh[10004]:         Master master2 joined the cluster                                                                                    
Nov 19 02:39:26 master1 bootkube.sh[10004]:         Master master3 joined the cluster                                                                                    
Nov 19 02:39:26 master1 bootkube.sh[10004]:         2 masters joined the cluster
Nov 19 02:39:26 master1 bootkube.sh[10004]: All self-hosted control plane components successfully started
Nov 19 02:39:26 master1 bootkube.sh[10004]: Sending bootstrap-success event. Waiting for remaining assets to be created.
```

Once bootkube has finished and the host has restarted run the following command to observe the installation of OpenShift:

```
aba run --cmd "get co"
aba run --cmd "get nodes"
```

## Other problems that might happen during mirroring: 

oc mirror fails with error "invalid mirror sequence order"
https://access.redhat.com/solutions/7026766

You might see the below error:

```
INFO Unable to retrieve cluster metadata from Agent Rest API: [GET /v2/clusters/{cluster_id}][404] v2GetClusterNotFound  &{Code:0xc0000b3c30 Href:0xc0000b3c40 ID:0xc000f06cec Kind:0xc0000b3c50 Reason:0xc0000b3c60} 
INFO Unable to retrieve cluster metadata from Agent Rest API: [GET /v2/clusters/{cluster_id}][404] v2GetClusterNotFound  &{Code:0xc000f855c0 Href:0xc000f855d0 ID:0xc000e80e5c Kind:0xc000f855e0 Reason:0xc000f855f0} 
ERROR Attempted to gather ClusterOperator status after wait failure: Listing ClusterOperator objects: Get "https://api.compact.example.com:6443/apis/config.openshift.io/v1/clusteroperators": tls: failed to verify certificate: x509: certificate is valid for kubernetes, kubernetes.default, kubernetes.default.svc, kubernetes.default.svc.cluster.local, openshift, openshift.default, openshift.default.svc, openshift.default.svc.cluster.local, 172.30.0.1, not api.compact.example.com 
INFO Use the following commands to gather logs from the cluster 
INFO openshift-install gather bootstrap --help    
ERROR Bootstrap failed to complete: : bootstrap process timed out: context deadline exceeded 
```

## Other Problems

Sometimes oc-mirror runs out of temporary disk space under /tmp.  You can fix this by increasing the space under /tmp or setting `data_dir` in `aba/mirror/mirror.conf` to a directory with more disk space:
```
sudo mount -o remount,size=6G /tmp
# or see: https://access.redhat.com/solutions/2843 
```

The actual installation of OpenShift might fail with an error similar to:

```
ERROR Bootstrap failed to complete: : bootstrap process timed out: context deadline exceeded
```

Use the following command to access the node to see if there are any problems:
```
aba ssh
```
Note: You can run `aba ssh` to easily log into the first node to troubleshoot the agent-based installation process. If ssh fails, you will need to take a look at the server's console and troubleshoot from there.  After fixing the problem, you may need to re-generate the agent configuration files, the ISO file, or both.  Run `aba clean` and then start again, such as by running `aba agentconf`. 

In tests, it was found that repeated installation of OpenShift using the exact same mac addresses tends to cause the install to either fail or to take a long time to complete.
When installing a fresh cluster, it is better not to run 'aba refresh' but to run 'aba clean' first and then run 'aba'. This will cause the configuration to be refreshed with random mac addresses (as long as "xx" is in use within the 'mac_prefix' parameter in the 'cluster.conf' file).

## Bare-metal BMC Automation

For bare-metal installs (`platform=bm` in cluster.conf), aba can mount the agent ISO on each node via Redfish VirtualMedia and one-shot boot - no manual virtual-media interaction required. Configure per-node BMC credentials in `bmc.conf` (mode 0600 enforced); see [templates/bmc.conf](templates/bmc.conf) for the schema.

### For operators: reading the output

aba emits one line per BMC event using the `BMC:` prefix. Lines are greppable; `aba install` is quiet on success.

**Line formats (per-node):**

```
BMC: <node> L1=ok L2=ok L3=ok L4=ok                        # preflight passed (irmc / redfish)
BMC: <node> L1=ok L2=ok L3=ok L4=ok L5=ok                  # preflight passed with vendor L5 gate (idrac / ilo / supermicro / lenovo)
BMC: <node> L<n>=FAIL reason="<message>"                   # preflight failed at level n (n=1..5)
BMC: <node> phase=<phase-name> adapter=<adapter> http=<code> reason="<reason>"   # runtime phase failure
BMC: <node> booted from ISO (adapter=<adapter>)            # per-node success
BMC: <ok>/<total> nodes booted from ISO                    # final summary (all success)
BMC: <ok>/<total> nodes booted from ISO; failed:<list>     # final summary (partial failure)
```

If a node hits the retry envelope, the failure line carries an `attempts=<N>` suffix (defaults: 3 attempts, 10s/20s backoff).

**Phase-name vocabulary (.bmc-state.\<node\> last_step):**

| Phase | What aba is doing | Common failure cause |
| :---- | :---------------- | :------------------- |
| session-login | POST /redfish/v1/SessionService/Sessions | Wrong credentials; rate-limited (PRE-07 warning) |
| discover | GET Managers / Systems / VirtualMedia | Vendor Manager id mismatch; license missing (L3) |
| eject-stale | EjectMedia if Inserted=true | Stale-media on previously-failed run |
| insert | POST VirtualMedia.InsertMedia (or PATCH for Lenovo) | URL with query params (PRE-05); chunked transfer (ERR-06) |
| wait-connected | Poll VirtualMedia.Inserted until true | Firmware accepted insert but did not present the device |
| boot-override | PATCH Boot (Cd / Once) | Cd not in allowables (UEFI vs Legacy BIOS); ETag race |
| reset | POST ComputerSystem.Reset (On or ForceRestart) | 401 after Reset (ERR-05 one-shot re-auth); HTTP 400 on halted node |
| wait-power | Poll PowerState=On | BMC firmware reports PowerState late |
| session-logout | DELETE session URI | Already invalidated; logged as warning |

**5 most common operator-fixable gaps:**

| Visible output | Probable cause | Fix |
| :------------- | :------------- | :-- |
| `BMC: <node> L1=FAIL` | `bmc_host` unreachable | Check network / firewall / DNS for `bmc_host_<node>` |
| `BMC: <node> L2=FAIL` | Wrong `bmc_password` | Verify `bmc.conf` mode 0600; rotate credential if needed |
| `BMC: <node> L3=FAIL reason="VirtualMedia not licensed"` | Vendor license gate | Contact BMC admin (see admin subsection for per-vendor entitlements) |
| `BMC: <node> L4=FAIL reason="neither Cd nor UsbCd in BootSourceOverrideTarget allowables"` | UEFI/Cd not enabled in BMC firmware boot setup | Enable UEFI boot in BMC firmware setup |
| `BMC: iso_url runtime guard failed - Transfer-Encoding: chunked present` | Operator-supplied `iso_url` returns chunked encoding | Remove explicit `iso_url` to use auto-derive, or replace proxy/CDN with a non-chunked HTTP server |

**Re-running after a fix:**

aba install resumes per-node from the last successful step. No special flag required. To wipe the per-node state and start fresh, run `aba clean` which removes `.bmc-state.<node>` files and any persisted session tempfiles.

### MAC discovery

For nodes with `bmc_host_<node>` set in bmc.conf, aba queries the BMC's Redfish EthernetInterfaces collection during preflight and either populates a missing `mac_<node>` from what the BMC reports, or validates the operator-supplied `mac_<node>` against the BMC's report. The discovered MAC is cached in `.bmc-state.<node>` so subsequent runs skip the Redfish call when nothing has changed.

#### How a NIC is selected

aba filters the BMC's EthernetInterfaces list to NICs that are both `LinkStatus=LinkUp` AND `InterfaceEnabled=true`, then drops any entry whose `InterfaceType` is `Bond` or whose name suggests a bond/team (e.g. iRMC's `iLO-bond0` entry). Result:

- Exactly 1 surviving NIC: that MAC is used (or compared to the operator's `mac_<node>`).
- 0 surviving NICs: `MAC-04: no enabled NIC with link reported for <node>` - check that at least one physical NIC is cabled and LinkUp on the BMC's view.
- More than 1 surviving NIC: `MAC-05: ambiguous - candidates for <node>: [...]; set mac_<node>=<address> in bmc.conf to disambiguate` - aba never guesses; the operator picks the correct NIC explicitly.

#### MAC-* error reference

| Code | Cause | Remediation |
| :--- | :---- | :---------- |
| MAC-03 | operator `mac_<node>` not in BMC's EthernetInterfaces report | Verify the MAC in bmc.conf matches a physical NIC on the node; remove a stale MAC from a swapped NIC. |
| MAC-04 | no LinkUp + Enabled NIC reported | Cable a NIC; enable the NIC in BIOS/iDRAC/iRMC; ensure the BMC reports the link state correctly. |
| MAC-05 | more than 1 LinkUp + Enabled NIC reported | Set `mac_<node>=<address>` in bmc.conf to pick the correct NIC explicitly. |
| MAC-08 | Redfish EthernetInterfaces call failed | Re-run preflight; check `BMC: <node>` line for the underlying HTTP code/reason. |
| MAC-09 | `mac_discovery_<node>=disabled` set without `mac_<node>` | Either remove the opt-out flag in bmc.conf, or set `mac_<node>` in bmc.conf. |

#### Opt-out

Set `mac_discovery_<node>=disabled` in bmc.conf to skip the Redfish call for a specific node. When opted out, `mac_<node>` MUST be set explicitly (in bmc.conf or via the existing `mac_master*`/`mac_worker*` mechanism in cluster.conf) or preflight aborts with MAC-09.

#### Per-vendor real-HW validation status (v1.1)

| Vendor | Code path | Real-HW validated in v1.1 | Notes |
| :----- | :-------- | :------------------------ | :---- |
| Fujitsu iRMC | generic DSP0266 (no override needed) | Yes | suite-bmc-mac-discovery.sh runs against iRMC in the lab pool. |
| Dell iDRAC9 | generic DSP0266 | No (deferred to v1.2) | Code-complete; mocked test coverage; report issues via GitHub. |
| HPE iLO 5/6 | generic DSP0266 | No (deferred to v1.2) | Code-complete; mocked test coverage; report issues via GitHub. |
| Supermicro X12/X13 | generic DSP0266 | No (deferred to v1.2) | Code-complete; mocked test coverage; report issues via GitHub. |
| Lenovo XCC | generic DSP0266 | No (deferred to v1.2) | Code-complete; mocked test coverage; report issues via GitHub. |

MAC discovery for the stretch vendors uses the same code path that already passes the Phase 8 boot gate against real hardware; the deferred-validation status applies only to the MAC discovery feature, not to the boot flow.

#### Behavior change vs. v1.1 without Phase 10

If you upgrade an existing bmc.conf-driven install (operator-set `mac_<node>` values present), aba now validates those MACs against the BMC's EthernetInterfaces report on every preflight run. A previously-working install can hard-fail at preflight with MAC-03 if the operator's MAC is on a NIC the BMC reports as `LinkDown` or `InterfaceEnabled=false`. Either cable the NIC, enable it in BMC firmware, or update `mac_<node>` to the currently-active NIC's MAC.

### For BMC admins: privileges, firmware, licenses

aba authenticates as a Redfish user against each node's BMC. Each vendor's RBAC model differs; the admin must grant the `bmc_user_<node>` enough privilege to read VirtualMedia, write Boot, and call Reset. Specific requirements per shipped vendor:

#### Fujitsu iRMC S5/S6

- **Required Redfish privilege/role**: "Configure BMC" role (or "Operator" with VirtualMedia + Power sub-rights). The user must be able to read `/redfish/v1/Managers/iRMC/VirtualMedia` and POST/PATCH against `Systems/0/Boot`.
- **Firmware floor**: lab-tested on iRMC S5 (2.51) and S6 (3.00P+). HTTPS-only behaviour on S6 2.00+.
- **License gate**: Fujitsu Advanced Pack (or equivalent) for VirtualMedia. Missing license shows as `BMC: <node> L3=FAIL reason="VirtualMedia not licensed on this BMC"`.
- **Auth-verify command** (run from the bastion to confirm the user can reach iRMC's Manager resource):

```bash
bmc_host=<your bmc fqdn>
bmc_user=<your bmc user>
bmc_password=<your bmc password>
auth=$(printf '%s:%s' "$bmc_user" "$bmc_password" | base64 -w0)
curl -sk -H "Authorization: Basic $auth" -H "Accept: application/json" \
     "https://$bmc_host/redfish/v1/Managers/iRMC" | jq '{Model, FirmwareVersion}'
# Expected: {"Model": "iRMC S6", "FirmwareVersion": "3.00P"} (or similar)
```

- **Remediation pointers**: Fujitsu PRIMERGY ServerView Suite -> User Management -> assign Configure BMC role; firmware updates via iRMC Web UI -> Tools -> Update.
- **Reference**: [Ironic iRMC driver documentation](https://docs.openstack.org/ironic/latest/admin/drivers/irmc.html) (public proxy for iRMC Redfish surface).

#### Dell iDRAC9

- **Required Redfish privilege/role**: "Operator" role with `VirtualMedia` and `ResetServer` permissions. iDRAC9 maps Redfish privileges to native iDRAC roles in the user-management UI.
- **Firmware floor**: 4.40.10.00 (Intel platforms) / 6.00.00.00 (AMD platforms). iDRAC10 is hard-failed (`iDRAC10 not yet supported - bmc_type=idrac targets iDRAC9 only in v1.1`); aba aborts with this verbatim message at preflight L5.
- **License gate**: Enterprise or Datacenter iDRAC license. Missing license shows as L3=FAIL or 403 on VirtualMedia endpoints.
- **Auth-verify command**:

```bash
bmc_host=<your bmc fqdn>
bmc_user=<your bmc user>
bmc_password=<your bmc password>
auth=$(printf '%s:%s' "$bmc_user" "$bmc_password" | base64 -w0)
curl -sk -H "Authorization: Basic $auth" -H "Accept: application/json" \
     "https://$bmc_host/redfish/v1/Managers/iDRAC.Embedded.1" | jq '{Model, FirmwareVersion}'
# Expected: {"Model": "Integrated Dell Remote Access Controller", "FirmwareVersion": "5.10.50.00"}
```

- **Remediation pointers**: iDRAC9 GUI -> iDRAC Settings -> Users -> assign Operator role; firmware updates via Lifecycle Controller or `racadm update`.
- **Reference**: [Dell iDRAC9 Redfish API guide](https://www.dell.com/support/manuals/en-us/idrac9-lifecycle-controller-v4.x-series/idrac9_4.00.00.00_redfishapiguide_pub/supported-action-insertmedia).

#### HPE iLO 5/6

- **Required Redfish privilege/role**: "Configure iLO Settings" + "Virtual Media" iLO privileges. iLO has a privilege matrix per user; the bmc_user must have both.
- **Firmware floor**: iLO 5 (2.40+) and iLO 6 (1.10+) supported. iLO 4 is hard-failed (`iLO 4 not supported - Redfish VirtualMedia non-standard; upgrade to iLO 5 or replace hardware`).
- **License gate**: iLO Advanced license required for VirtualMedia. Missing license shows as 403 or 501 on VirtualMedia.InsertMedia.
- **Auth-verify command**:

```bash
bmc_host=<your bmc fqdn>
bmc_user=<your bmc user>
bmc_password=<your bmc password>
auth=$(printf '%s:%s' "$bmc_user" "$bmc_password" | base64 -w0)
curl -sk -H "Authorization: Basic $auth" -H "Accept: application/json" \
     "https://$bmc_host/redfish/v1/Managers/1" | jq '{Model, FirmwareVersion}'
# Expected: {"Model": "iLO 5", "FirmwareVersion": "2.78"} (or iLO 6 / 1.45)
```

- **Remediation pointers**: iLO Web UI -> Administration -> User Administration -> grant "Virtual Media" privilege; firmware updates via HPE iLO firmware tar bundle.
- **Reference**: [HPE iLO 6 REST API reference](https://hewlettpackard.github.io/ilo-rest-api-docs/ilo6/).

#### Supermicro X12/X13

- **Required Redfish privilege/role**: "Administrator" or BMCAdmin (Supermicro X12/X13 BMC has a small role set; admin is the typical grant for tooling).
- **Firmware floor**: lab-tested on X12 BMC 1.04+ and X13 BMC 1.00.20+. X11 is unsupported (older Supermicro BMCs use a different vendor extension).
- **License gate**: SFT-OOB-LIC or SFT-DCMS-SINGLE may be required for VirtualMedia depending on motherboard SKU.
- **Auth-verify command**:

```bash
bmc_host=<your bmc fqdn>
bmc_user=<your bmc user>
bmc_password=<your bmc password>
auth=$(printf '%s:%s' "$bmc_user" "$bmc_password" | base64 -w0)
curl -sk -H "Authorization: Basic $auth" -H "Accept: application/json" \
     "https://$bmc_host/redfish/v1/Managers/1" | jq '{Model, FirmwareVersion}'
# Expected: {"Model": "X12STH-LN4F", "FirmwareVersion": "01.04.00"} (or similar X-series)
```

- **Remediation pointers**: Supermicro IPMI Web UI -> User Management -> assign Administrator privilege; firmware updates via IPMICFG or BMC Web UI.
- **Reference**: [Supermicro Redfish reference guide - VirtualMedia](https://www.supermicro.com/manuals/other/redfish-ref-guide-html/Content/general-content/virtual-media-management.htm).

#### Lenovo XCC

- **Required Redfish privilege/role**: "ReadWrite" (lnv-bmc-admin equivalent) with RemoteMedia / VirtualMedia feature. Lenovo XCC uses fine-grained Redfish privileges on the user account.
- **Firmware floor**: XCC 8.x+ (lab-tested on Lenovo ThinkSystem SR/SD series).
- **License gate**: Enterprise Upgrade license required for the XCC RemoteMedia / VirtualMedia feature. Missing license shows as `BMC: <node> L5=FAIL reason="Lenovo XCC license tier missing RemoteMedia/VirtualMedia feature; Enterprise license required..."` (verbatim message references KCS 6958685 for context).
- **Auth-verify command**:

```bash
bmc_host=<your bmc fqdn>
bmc_user=<your bmc user>
bmc_password=<your bmc password>
auth=$(printf '%s:%s' "$bmc_user" "$bmc_password" | base64 -w0)
curl -sk -H "Authorization: Basic $auth" -H "Accept: application/json" \
     "https://$bmc_host/redfish/v1/Managers/1" | jq '{Model, FirmwareVersion}'
# Expected: {"Model": "XClarity Controller 2", "FirmwareVersion": "8.00"} (or similar)
```

- **Remediation pointers**: Lenovo XCC Web UI -> XCC Server Configuration -> Features on Demand -> activate Enterprise Upgrade key; firmware updates via XCC Update Wizard.
- **Reference**: [Lenovo XCC REST API - VirtualMedia PATCH](https://pubs.lenovo.com/xcc-restapi/insert_eject_virtual_media_patch).

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

After fixing the RBAC or the configuration, re-run `aba install`. No extra
flag is needed - preflight runs automatically on every install attempt.

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

