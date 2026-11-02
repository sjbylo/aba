# ADR-018: VM Ownership Tag (Cluster Identity in VM Metadata)

## Status
Proposed

## Context
ABA creates VMs on KVM and VMware during cluster installation.  VMs are named
with a prefix derived from the cluster directory name (e.g. `mycluster-master1`).
Today, ABA assumes that if a VM with the expected name exists, it belongs to
the current cluster directory.

This assumption breaks when:

1. A cluster dir is deleted (`rm -rf`) but VMs remain on the hypervisor — a
   new cluster dir with the same name inherits orphaned VMs it didn't create.
2. Two users (or two cluster dirs) use the same cluster name on the same
   hypervisor — ABA cannot distinguish whose VMs are whose.
3. `make clean` + re-init resets all local state but VMs still exist — the new
   instance may try to adopt VMs from a previous installation attempt.

ABA already writes descriptive annotations on every VM it creates (see
`_vm_annotation()` in `include_all.sh`) — a human-readable block with cluster
name, OCP version, ABA version, and install date.  But there is no
machine-readable identifier tying a VM to a specific cluster directory instance.

## Decision
Embed a short machine-readable ownership tag in VM metadata using hypervisor
extra-config fields (not the human-readable annotation).  Use this tag at
check time to verify that VMs belong to the current cluster instance.

### ID format
An 8-character hex string generated once per cluster directory lifetime:

```bash
head -c4 /dev/urandom | xxd -p   # e.g. a3f2b7c1
```

This gives ~4 billion combinations — more than sufficient for distinguishing
cluster instances on the same hypervisor.

### Storage mechanism

**VMware** — `guestinfo` extra-config key (structured, separate from
human-readable annotation):

```bash
govc vm.change -vm "$vm_name" -e guestinfo.aba-cluster-id="$cluster_id"
```

ABA already requires `VirtualMachine.Config.AdvancedConfig` privilege at both
FOLDER and DATACENTER scope — no additional permissions needed.

**KVM** — libvirt metadata XML:

```bash
virsh metadata "$vm_name" --uri https://github.com/sjbylo/aba \
    --set "<aba><cluster-id>$cluster_id</cluster-id></aba>"
```

### Identity lifecycle
- **Generated**: when `make init` creates the cluster directory
  (`head -c4 /dev/urandom | xxd -p` → `.cluster-id` file).
- **Stored**: `.cluster-id` in the cluster directory root (alongside
  `cluster.conf`, `.init`, etc.).
- **Embedded**: written to VM extra-config at creation time as
  `guestinfo.aba-cluster-id` (VMware) or libvirt metadata XML (KVM).
- **Compared**: by `check-vm-state.sh` (called from Makefile `check`
  target) and by `aba delete`.
- **Preserved**: survives `aba delete` (VMs are destroyed, `.cluster-id`
  stays).  Survives directory moves/copies (the file travels with the dir).
- **Regenerated**: only by `make clean` (full reset) or manual removal.

### Write path (VM creation)
At VM creation time, after the existing annotation write:

- **VMware**: `govc vm.change -vm "$vm_name" -e guestinfo.aba-cluster-id="$cluster_id"`
  (piggybacks on the existing `govc vm.change` call that sets `disk.enableUUID`,
  `cpu-hot-add-enabled`, etc. — can be combined into one call).
- **KVM**: `virsh metadata` call after the existing `virsh desc` calls.

### Read path (VM ownership check)
New function `vm_owned_by_us()` in `vm-provider.sh`:

- Reads the ownership tag of one existing VM (the first found).
- Compares against the local `.cluster-id` file.
- Returns:
  - 0 = match (VMs are ours)
  - 1 = mismatch (VMs belong to a different instance)
  - 2 = cannot read (hypervisor unreachable)
  - 3 = skip (no tag on VM or no `.cluster-id` locally — ownership
    check does not apply; feature only activates when both sides have IDs)

Provider primitives:
- **VMware**: `govc vm.info -json $vm | jq -r '.virtualMachines[0].config.extraConfig[] | select(.key=="guestinfo.aba-cluster-id") .value'`
  (the `vm.info` JSON is already fetched by `vmp_exists` — can piggyback
  on cached data with zero extra API calls).
- **KVM**: `virsh metadata "$vm" --uri https://github.com/sjbylo/aba`
  (one extra libvirt call per check, ~50ms).

### Evaluation points and actions

All VM state logic lives in **external scripts** called from thin Makefile
targets — consistent with ABA's existing pattern where Makefiles are
orchestrators and scripts contain the logic.

#### 1. Makefile `check` target → `check-vm-state.sh`

The Makefile calls a single script:

```makefile
ifdef HV_PREFIX
	@$(SCRIPTS)/check-vm-state.sh
endif
```

`check-vm-state.sh` handles all VM state validation:

- `.autorefresh` not present → exit 0 (nothing to check)
- VMs exist + ownership matches (rc=0) → exit 0 (proceed normally)
- VMs exist + ownership mismatch (rc=1) → **exit 1 with error**:
  `VMs exist but belong to a different cluster instance.
  Use 'aba delete --force' to remove them, or rename this cluster.`
  Refusing to proceed is critical: the subsequent Make chain
  (kill → refresh → delete + create) would destroy foreign VMs.
- VMs exist + ownership skip (rc=3) → exit 0 (no tag = check doesn't apply)
- VMs gone (rc=1 from exists) → remove stale markers, exit 0
- Hypervisor unreachable (rc=2) → warn, exit 0

#### 2. `aba delete` command

**When**: user requests VM deletion.

**Actions**:
- ID matches → delete normally
- ID mismatch (without `--force`) → refuse with error: `VMs were created
  by a different instance (ID: a3f2b7c1). Use --force to delete anyway.`
- ID mismatch (with `--force`) → warn and proceed with deletion
- No tag / no `.cluster-id` → delete normally (check doesn't apply)

#### 3. `aba info` / `aba ls` (display only)

Show ownership status alongside VM information:
- `✓ owned` / `⚠ foreign` / (no indicator when check doesn't apply)

### Bare-metal
Bare-metal has no VM metadata mechanism.  The `.cluster-id` file is still
generated (for consistency) but ownership checks are skipped.  The `HV_PREFIX`
guard already handles this (bare-metal has no `HV_PREFIX`).

## Consequences
- Eliminates false VM adoption when cluster names collide.
- **Fail-safe, not fail-silent**: ownership mismatch stops with an error
  rather than silently proceeding into destructive territory.  The user
  must explicitly use `--force` to override.
- **Feature activates naturally**: the ownership check only applies when
  both sides have IDs (`.cluster-id` locally and tag on the VM).  VMs
  created before this feature simply skip the check — no special handling,
  no migration, no warnings.
- **Logic in scripts, not Makefiles**: all VM state validation lives in
  `check-vm-state.sh` — testable, readable, extensible.  The Makefile
  has a single one-line call.
- Stale marker detection becomes authoritative: knows whether VMs are "ours"
  vs orphaned vs foreign.
- Structured key-value metadata — clean separation from the human-readable
  annotation text.
- Slight overhead on KVM: one extra `virsh metadata` call per ownership check
  (~50ms).
- No overhead on VMware: extra-config is already in the `vm.info` JSON
  response that `vmp_exists` fetches.
- Does not help bare-metal (no hypervisor metadata), but bare-metal doesn't
  have stale VM issues.
- The `.cluster-id` file becomes part of the cluster identity — backup/restore
  workflows should preserve it.

## Alternatives considered
1. **Annotation text line** (`ABA-Cluster-ID: <id>` in the human-readable
   annotation) — simpler but mixes machine data with human text; harder to
   parse reliably.
2. **VM name suffix** (e.g. `mycluster-master1-a3f2`) — zero read overhead
   but changes visible VM naming; breaks user expectations of predictable
   names.
3. **MAC address fingerprint** — uses data already assigned in
   `agent-config.yaml`; zero creation changes but needs extra API calls to
   read MACs and doesn't survive VM re-creation.
4. **Hash of cluster dir absolute path** — breaks if the directory is moved;
   ties identity to filesystem location rather than the instance.
5. **Full UUID** (36 chars) — unnecessarily long for this use case; 8 hex
   chars provide sufficient uniqueness.
6. **VM tags (vSphere)** — requires additional vSphere privileges (`Tagging`),
   not available on all deployments.
7. **Do nothing** (rely on name-only matching) — status quo; insufficient for
   the multi-user and stale-marker scenarios.
8. **Inline Makefile logic** — put the check/ownership logic directly in
   Makefile recipes.  Violates ABA's pattern of thin Makefiles calling
   external scripts; harder to test and read due to `$$` escaping and
   `\` continuations.

## References
- ADR-004: Marker files for state tracking
- `scripts/include_all.sh`: `_vm_annotation()`
- `scripts/vm-provider.sh`: `vm_exists_any()`
- `scripts/vm-vmw.sh`: `vmp_create_vm()` — existing `govc vm.change -e` call
- `scripts/kvm-create.sh`: `virsh desc` annotation writes
- `scripts/vmware-required-privileges.sh`: `VirtualMachine.Config.AdvancedConfig`
  already required at FOLDER and DATACENTER scope
