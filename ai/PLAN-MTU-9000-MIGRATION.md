# Plan: Migrate Lab Network to MTU 9000 (Jumbo Frames)

**Created**: 2026-04-02
**Status**: Draft

---

## 1. Why Jumbo Frames?

Standard Ethernet frames carry 1500 bytes of payload. Jumbo frames carry up to 9000 bytes,
reducing per-packet overhead (headers, interrupts, CPU cycles). Benefits:

- **NFS performance**: Fewer packets for the same data = less CPU overhead, higher throughput.
  On 10GbE links the gain can be 10-30%. On 1GbE the gain is smaller (~5-10%) but still real,
  especially for large sequential I/O (VM disk images, ISO transfers).
- **vMotion speed**: Memory pages are large contiguous blocks -- jumbo frames reduce packet
  count significantly during live migration.
- **Storage vMotion**: Same benefit as NFS -- fewer packets for large block transfers.

**The golden rule**: Every device in the path must support the same MTU. If even one hop
is MTU 1500, jumbo frames either fragment (slow) or get dropped (broken). This means
NIC → vSwitch → VMkernel → physical cable → physical switch port → NAS NIC must ALL be 9000.

---

## 2. Current State (as of 2026-04-02)

### 2.1 ESXi Hosts

| Host   | Role  | NICs                                   | vSwitch0 MTU | vmk0 MTU | Other vSwitches       |
|--------|-------|----------------------------------------|:------------:|:--------:|-----------------------|
| esxi1  | NUC   | vmnic0 (1GbE Intel I219-V)             | 1500         | 1500     | --                    |
| esxi2  | NUC   | vmnic0 (1GbE Intel I219-V)             | 1500         | 1500     | --                    |
| esxi3  | NUC   | vmnic0 (1GbE Intel I219-V)             | 1500         | 1500     | --                    |
| esxi4  | DELL  | vmnic0 (1GbE I219-LM), vmnic1+2 (10GbE X550) | 1500   | 1500     | vSwitch-Private=9000, vSwitch-External=1500 |

**Note**: esxi4's `vSwitch-Private` is ALREADY at MTU 9000 (no uplink -- internal only).

### 2.2 NAS (Synology, 10.0.1.8)

- NFS export: `/volume1/nfs-vmware` mounted as `NFS-Shared` on all 4 hosts
- SSH is disabled -- configuration must be done via DSM Web UI (port 5001)
- Current MTU: **check via DSM > Network > Network Interface**
- NAS has **10GbE** port (on 10G lab network) + 2x 2.5GbE ports (internet-facing)
- The 10GbE NAS port connects to the 10G managed switch

### 2.3 Physical Switches

| Device               | IP/Mgmt  | Ports | Type      | Jumbo Frame Status |
|----------------------|----------|-------|-----------|---------------------|
| D-Link 10G managed   | 10.0.0.2 (Lab) | 8 | Managed | **ALREADY ENABLED** -- 10000 bytes (Port > Jumbo Frame > Enable) |
| TP-Link TL-SG108 1G  | --       | 8     | Unmanaged | **YES** -- supports 16 KB jumbo natively (chipset-level, no config needed) |

**Network topology**:
- D-Link 10G managed: DELL (esxi4 vmnic1+2), NAS (10GbE), MacBook, internet uplink, TP-Link uplink
- TP-Link TL-SG108 1G: 3 NUCs (esxi1-3), daisy-chained to D-Link 10G switch

**Both switches already support jumbo frames -- no switch changes needed!**
The D-Link is already set to 10000 bytes (covers 9000 MTU + headers).
The TP-Link TL-SG108 handles up to 16 KB natively.

### 2.4 VMs (Guest OS)

| VM       | Interfaces                          | MTU  |
|----------|-------------------------------------|:----:|
| bastion  | ens3 (Lab), ens4 (Private)          | 1500 |
| con1     | ens192 (Lab), ens224 (Private), ens256 (External), ens224.10 (VLAN) | 1500 |
| con2     | (unreachable)                       | 1500 (assumed) |

**VMs DO need MTU 9000** on their guest NICs to benefit from jumbo frames. Here's why:

- The vSwitch sets the **maximum** frame size it will pass, but the guest OS decides what
  MTU to actually use. If vmk0 and the vSwitch are 9000 but the VM guest NIC is 1500,
  the VM still sends 1500-byte frames -- it never generates jumbo frames.
- For **VM ↔ VM traffic** across hosts: both VMs' guest NICs must be 9000, plus the
  vSwitch and physical path in between.
- For **VM → NAS** (e.g. bastion doing NFS mounts, `scp`, `rsync`): the VM guest NIC
  must be 9000 for the VM to send/receive jumbo frames to the NAS.
- For **VM → internet**: leave at 1500 (internet doesn't support jumbo frames).
  Only the Lab-facing NIC (ens192/ens3) should be 9000. External-facing NICs stay 1500.

**Previously we had MTU 9000 set on E2E VMs** (con1/con2/dis1/dis2) and it caused
problems because the physical switches weren't configured for it. That was removed.
Once the physical path supports jumbo, VM guest MTU should be re-enabled.

### 2.5 vMotion

All 4 hosts use `vmk0` on `Management Network` (vSwitch0) for vMotion at MTU 1500.

---

## 3. Decision Points

### 3.1 Which traffic benefits from jumbo frames?

| Traffic Type              | Path                                   | Benefit | Priority |
|---------------------------|----------------------------------------|---------|----------|
| NFS (VM storage)          | ESXi vmk → switch → NAS               | HIGH    | 1        |
| vMotion                   | ESXi vmk → switch → ESXi vmk          | HIGH    | 2        |
| VM ↔ NAS (rsync/scp/NFS)  | VM guest → vSwitch → switch → NAS     | HIGH    | 3        |
| VM ↔ VM (diff host)       | VM guest → vSwitch → switch → vSwitch → VM guest | MEDIUM  | 4        |
| VM ↔ VM (same host)       | VM guest → vSwitch → VM guest         | LOW     | 5        |
| Management                | vmk0 → switch → bastion               | LOW     | 6        |

**Note**: VM guest NIC MTU must ALSO be 9000 for rows 3-5. The vSwitch sets the ceiling;
the guest OS sets the actual frame size used.

### 3.2 Dedicated VMkernel for NFS/vMotion?

**Option A: Change vmk0 (Management Network) to MTU 9000**
- Simplest. All traffic (management + NFS + vMotion) goes through one VMkernel.
- Risk: if jumbo frames break, you lose management access to the host.
- NUCs only have 1 NIC, so there's no alternative path anyway.

**Option B: Create a separate vmk1 for NFS/vMotion at MTU 9000**
- Safer: management stays at 1500, storage/vMotion at 9000.
- Problem: NUCs have only 1 NIC (vmnic0). A second VMkernel on the same NIC doesn't
  truly isolate traffic -- both VMkernels share the same physical path and the vSwitch
  MTU must be the max of all its VMkernels.
- For esxi4 (DELL with 10GbE), this makes sense: put NFS/vMotion on vmnic1 (10GbE).

**Recommendation**: Option A for NUCs (simple, one NIC), Option B for esxi4 (10GbE).

### 3.3 Thought: Should we do esxi4 (10GbE) only first?

The NUCs are 1GbE. Jumbo frames on 1GbE give maybe 5-10% improvement for NFS.
esxi4 has 10GbE where the benefit is 10-30%. The NAS also has 10GbE on the managed switch.

Since both switches support jumbo frames, we can enable MTU 9000 on **all hosts in one pass**.
The biggest performance gain is on the esxi4 ↔ NAS 10GbE path, but the NUCs also benefit
from reduced per-packet overhead on NFS and vMotion traffic.

---

## 4. Prerequisites (MUST complete before any changes)

- [x] **P1: Identify physical switches** -- 8-port 10G **managed** switch (supports jumbo, needs config)
      + 8-port 1G TP-Link **unmanaged desktop** switch (supports 15-16 KB jumbo natively).
- [x] **P2: Verify NAS NIC speed** -- NAS has **10GbE** port on 10G managed switch.
- [ ] **P3: Check NAS current MTU** -- DSM > Network > Network Interface > Edit. Likely 1500.
- [x] **P4: Configure 10G managed switch for jumbo** -- D-Link at 10.0.0.2 already set to 10000 bytes.
- [x] **P5: Back up vCenter VM** -- DONE (snapshot: `pre-mtu9000-backup` on esxi2/Datastore2).
- [ ] **P6: Ensure no E2E tests are running** -- MTU changes will briefly disrupt NFS I/O.
- [ ] **P7: Document rollback procedure** -- see Section 7 below.

---

## 5. Migration Steps (Ordered)

**IMPORTANT**: Change order matters! Always go "inside out":
1. Physical switch first (it must accept jumbo frames before anything sends them)
2. NAS second (storage endpoint)
3. ESXi vSwitch third (raises the frame-size ceiling)
4. ESXi VMkernel last (actually starts sending jumbo frames)

If you do it backwards (ESXi first), jumbo frames hit a 1500-MTU switch and get dropped,
causing NFS I/O errors and potential VM crashes.

### Phase 1: Physical Switch Configuration -- ALREADY DONE

**D-Link 10G managed switch** (10.0.0.2):
- Jumbo Frame: **ENABLED**, set to **10000 bytes** (Port > Jumbo Frame).
- No further action needed.

**TP-Link TL-SG108 1G** (NUCs):
- No configuration needed. The TL-SG108 supports **16 KB jumbo frames** natively.
- Still verify with `vmkping -s 8972 -d` after enabling jumbo on the NUCs, just to be safe.

### Phase 2: NAS (Synology) Configuration

```
Step 2.1: Log into DSM at https://10.0.1.8:5001
Step 2.2: Control Panel > Network > Network Interface
Step 2.3: Select the active interface (LAN 1 or bond0)
Step 2.4: Click Edit > set MTU to 9000
Step 2.5: Apply (this will briefly drop the NFS connection -- VMs may pause)
```

**Timing**: Do this during a maintenance window. ESXi hosts will see NFS become
temporarily unavailable. VMs on NFS-Shared may freeze for a few seconds.

### Phase 3: ESXi vSwitch MTU (all hosts)

Run on each host. Start with esxi4 (has fewest VMs, easiest to test):

```bash
# For each host (esxi1-esxi4):
ssh -F ~/.aba/ssh.conf root@esxiN.lan

# Raise vSwitch0 MTU to 9000
esxcli network vswitch standard set -v vSwitch0 -m 9000

# Verify
esxcli network vswitch standard list -v vSwitch0 | grep MTU
```

For esxi4, also set vSwitch-External if desired:
```bash
esxcli network vswitch standard set -v vSwitch-External -m 9000
```

**Note**: Changing vSwitch MTU does NOT change VMkernel MTU. The vSwitch just allows
larger frames to pass through -- nothing actually sends them until vmk MTU is raised.

### Phase 4: ESXi VMkernel MTU

```bash
# For each host:
ssh -F ~/.aba/ssh.conf root@esxiN.lan

# Raise vmk0 MTU to 9000
esxcli network ip interface set -i vmk0 -m 9000

# Verify
esxcli network ip interface list | grep -A5 vmk0 | grep MTU
```

**Test immediately after each host**:
```bash
# From the ESXi host, ping the NAS with jumbo frames:
vmkping -s 8972 -d 10.0.1.8
# -s 8972 = 9000 - 20 (IP header) - 8 (ICMP header)
# -d = set DF (Don't Fragment) bit -- forces jumbo or fail
# SUCCESS = "8972 bytes from 10.0.1.8: ..."
# FAILURE = "packet needs to be fragmented" or timeout
```

```bash
# Ping another ESXi host (vMotion path):
vmkping -s 8972 -d 10.0.1.20   # esxi2 from esxi1, etc.
```

### Phase 5: VM Guest MTU

VMs need their guest NICs set to MTU 9000 to generate/accept jumbo frames.
Only set MTU 9000 on **Lab-facing NICs**. External/internet NICs stay at 1500.

**Persistent VMs** (bastion, con1, con2, dis1, dis2):
```bash
# SSH into each VM and set Lab NIC to MTU 9000:

# bastion (ens3 = Lab):
nmcli connection modify ens3 802-3-ethernet.mtu 9000
nmcli connection up ens3

# con1/con2 (ens192 = Lab):
nmcli connection modify ens192 802-3-ethernet.mtu 9000
nmcli connection up ens192

# Also set Private Network NIC if desired (ens224 / ens4):
nmcli connection modify ens224 802-3-ethernet.mtu 9000
nmcli connection up ens224
```

**E2E pool VMs** -- update the pool-lifecycle setup so newly cloned VMs get MTU 9000:
- `test/e2e/lib/pool-lifecycle.sh` `_vm_setup_network` function
- `test/e2e/lib/vm-helpers.sh` nmcli commands
- These were previously set to 9000 and then removed (caused problems when switches
  weren't configured). Re-add once the physical path supports jumbo.

**VM templates** (golden images) -- optionally bake MTU 9000 into the template so all
cloned VMs inherit it. Alternative: set it at first boot via cloud-init or the
pool-lifecycle scripts.

**OCP cluster nodes** -- CoreOS VMs. MTU is set via the `install-config.yaml`
`networking.networkType` and `machineNetwork` settings, or via MachineConfig day-2.
For OCP clusters on the Lab network, a MachineConfig can set the primary NIC to MTU 9000:
```yaml
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  name: 99-jumbo-mtu
  labels:
    machineconfiguration.openshift.io/role: worker
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
        - path: /etc/NetworkManager/dispatcher.d/99-jumbo-mtu.sh
          mode: 0755
          contents:
            inline: |
              #!/bin/bash
              if [ "$1" = "ens192" ] && [ "$2" = "up" ]; then
                ip link set ens192 mtu 9000
              fi
```

### Phase 6: Verify NFS Performance

```bash
# Before/after comparison -- run on an ESXi host:
# Time a large file copy on NFS datastore
time cp /vmfs/volumes/NFS-Shared/some-large-file.vmdk /vmfs/volumes/NFS-Shared/test-copy.vmdk
# Compare times before and after jumbo frames
```

---

## 6. Verification Checklist

Run this after completing all phases to confirm end-to-end jumbo frame support:

- [ ] **V1**: `vmkping -s 8972 -d 10.0.1.8` from every ESXi host → NAS (NFS path)
- [ ] **V2**: `vmkping -s 8972 -d 10.0.1.XX` between every pair of ESXi hosts (vMotion path)
- [ ] **V3**: `esxcli network vswitch standard list` shows MTU 9000 on all vSwitches
- [ ] **V4**: `esxcli network ip interface list` shows MTU 9000 on all vmk adapters
- [ ] **V5**: NFS-Shared is accessible and VMs are running normally
- [ ] **V6**: vMotion test: live migrate a small VM between hosts
- [ ] **V7**: Storage vMotion test: move a VM between local and NFS-Shared datastores
- [ ] **V8**: VM guest MTU: `ip link show ens192` (or ens3) shows `mtu 9000` inside each VM
- [ ] **V9**: VM-to-VM jumbo ping: `ping -M do -s 8972 <other-vm>` from inside a VM
- [ ] **V10**: VM-to-NAS jumbo ping: `ping -M do -s 8972 10.0.1.8` from bastion
- [ ] **V11**: `bash ai/check-mtu-state.sh 9000` -- all green
- [ ] **V12**: E2E test suite passes with MTU 9000 re-enabled in pool-lifecycle scripts

---

## 7. Rollback Procedure

If jumbo frames cause problems (NFS errors, VM freezes, vMotion failures):

```bash
# Revert VMkernel MTU (on each ESXi host):
esxcli network ip interface set -i vmk0 -m 1500

# Revert vSwitch MTU (on each ESXi host):
esxcli network vswitch standard set -v vSwitch0 -m 1500

# Revert NAS MTU (via DSM Web UI):
# Control Panel > Network > Network Interface > Edit > MTU 1500

# Revert switch (via web UI):
# Set jumbo frame / max frame size back to 1518 / disabled
```

**Rollback order is reverse**: VMkernel → vSwitch → NAS → switch.
This ensures nothing sends jumbo frames into a path that no longer accepts them.

---

## 8. State-Check Script

A script to audit the current MTU state of all components exists at `ai/check-mtu-state.sh`.

```bash
# Report current state (baseline):
bash ai/check-mtu-state.sh

# Verify everything is at MTU 9000 (post-migration):
bash ai/check-mtu-state.sh 9000
```

The script checks all ESXi vSwitches, VMkernels, physical NICs, NAS reachability,
and (in verification mode) runs jumbo-frame ping tests between all hosts and the NAS.

---

## 9. Risk Assessment

| Risk                                    | Impact | Mitigation                              |
|-----------------------------------------|--------|-----------------------------------------|
| 1G TP-Link TL-SG108 edge case           | LOW    | TL-SG108 supports 16 KB jumbo; verify with vmkping after config |
| NFS drops during NAS MTU change         | HIGH   | Schedule maintenance window; warn VMs may pause briefly |
| vmk0 MTU change breaks management       | HIGH   | Have IPMI/iDRAC/physical console ready; do one host at a time |
| Mismatched MTU causes silent packet loss| HIGH   | Use vmkping -s 8972 -d to verify end-to-end after EACH change |
| VM guest MTU mismatch with host         | MEDIUM | Set VM guest NICs to 9000 on Lab NIC; leave External at 1500 |
| E2E tests break after re-adding MTU 9000| MEDIUM | Test on one pool first; the previous MTU removal commit is the rollback point |
| OCP nodes need MachineConfig for MTU    | LOW    | Day-2 operation; document in OCP post-install checklist |

---

## 10. Thoughts & Open Questions

1. **Is this worth it for 1GbE NUCs?** The biggest win is on esxi4's 10GbE links.
   For NUCs, the 1GbE link is the bottleneck, not packet overhead. But since the TP-Link
   desktop switch supports jumbo natively, there's zero downside to enabling it everywhere.

2. **NAS is 10GbE -- RESOLVED.** NAS has a 10GbE port on the managed switch. The esxi4 ↔ NAS
   path is fully 10GbE and will benefit greatly from jumbo frames. NUCs still go through the
   1G switch as a bottleneck, but jumbo frames still reduce CPU overhead at 1GbE.

3. **Should vMotion use a dedicated VMkernel?** Best practice says yes, but with single-NIC
   NUCs it's moot -- all traffic shares one physical path. On esxi4, putting vMotion on
   the 10GbE NIC (vmnic1) with a dedicated vmk1 would be ideal.

4. **MTU 9000 vs 9216?** The vSwitch and VMkernel use 9000 (payload). Physical switches
   typically need 9216 (payload + Ethernet overhead). Set the managed switch to 9216 or "max".

5. **VLAN tags and MTU**: If using VLANs (802.1Q), the VLAN tag adds 4 bytes to the frame.
   This is why switches should be set to 9216 (allows 9000 payload + headers + VLAN tag).

6. **esxi4 vSwitch-Private is already 9000** -- this was set during initial setup for
   internal VM-to-VM traffic. No uplink, so no physical switch involvement. It works because
   the frames never leave the host.

7. **E2E pool VMs had MTU 9000 before -- it was removed.** The `pool-lifecycle.sh` and
   `vm-helpers.sh` scripts used to set `802-3-ethernet.mtu 9000` on con/dis VMs. It was
   removed because the physical switches weren't configured for it, causing silent packet
   loss and hung SSH/rsync sessions. Once the physical path supports jumbo, re-add those
   lines to the E2E scripts.

8. **OCP cluster VMs** need a MachineConfig to set MTU 9000 on their Lab NIC. This is a
   day-2 operation. Alternatively, set MTU in `install-config.yaml` at install time if
   the `networking` section supports it for the platform.

---

## 11. Summary: Execution Order

**What we know**:
- D-Link 10G managed (10.0.0.2): jumbo frames **ALREADY enabled** at 10000 bytes
- TP-Link TL-SG108 1G: supports 16 KB jumbo natively (no config needed)
- NAS: 10GbE port on D-Link managed switch

**Execution order**:
1. **Check NAS current MTU** (SSH port 22000 or DSM Web UI)
2. ~~Configure 10G managed switch~~ -- **ALREADY DONE** (D-Link at 10.0.0.2, 10000 bytes)
3. **Set NAS MTU to 9000** (brief NFS disruption)
4. **Set all ESXi vSwitch0 MTU to 9000** (esxi4 first, then esxi1-3)
5. **Set all ESXi vmk0 MTU to 9000** → test `vmkping -s 8972 -d` after each host
6. **Set VM guest NICs to 9000** (Lab NIC only) on bastion, con1, con2, etc.
7. **Re-add MTU 9000 to E2E pool-lifecycle scripts** for future pool VM clones
8. **Run `bash ai/check-mtu-state.sh 9000`** to verify everything
9. **(Optional)** Apply MachineConfig to OCP cluster nodes for jumbo frames
