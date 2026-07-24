#!/usr/bin/env bash
# =============================================================================
# E2E Test Framework -- VM Clone & NIC Operations
# =============================================================================
# ESXi/vCenter clone logic, VM existence checks, NIC management, destroy.
# Split from vm-ops.sh.
# =============================================================================

_E2E_LIB_DIR_VMCLONE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source remote helpers if not already loaded
if ! type _wait_for_ssh >/dev/null; then
	source "$_E2E_LIB_DIR_VMCLONE/remote.sh"
fi
if ! type pool_domain >/dev/null; then
	source "$_E2E_LIB_DIR_VMCLONE/config-helpers.sh"
fi

# --- govc VM primitives (used by setup-infra.sh and pool-ops.sh) -------------

# Detect standalone ESXi (HostAgent) vs vCenter (VirtualCenter).
# Cached for the lifetime of the shell.
_GOVC_API_TYPE=""
_is_esxi() {
	if [ -z "$_GOVC_API_TYPE" ]; then
		_GOVC_API_TYPE=$(govc about -json \
			| python3 -c "import json,sys; print(json.load(sys.stdin).get('about',{}).get('apiType',''))") || true
	fi
	[ "$_GOVC_API_TYPE" = "HostAgent" ]
}

vm_exists() {
	local vm_name="$1"
	govc vm.info "$vm_name" | grep -q "Name:"
}

# Set VM annotation (vCenter "Notes" field) to show current lifecycle stage.
_vm_annotate() {
	local vm="$1"
	local status="$2"
	govc vm.change -vm "$vm" -annotation "Status: $status
Updated: $(date '+%Y-%m-%d %H:%M:%S %Z')
Managed by: E2E framework (setup-infra.sh)" || true
}

# Get the VMware port group name for a NIC (standard or dvSwitch).
_get_nic_network() {
	local vm="$1"
	local device="$2"

	local pg_key
	pg_key=$(govc device.info -vm "$vm" -json "$device" \
		| jq -r '.devices[0].backing.port.portgroupKey // empty')

	if [ -n "$pg_key" ]; then
		govc object.collect -s "$pg_key" name
	else
		govc device.info -vm "$vm" "$device" \
			| awk '/Summary:/{$1=""; print substr($0,2)}'
	fi
}

# Clone a VM from a source, set MAC addresses, expand disk, and power on.
# After cloning (powered off), MAC addresses from VM_CLONE_MACS are applied
# so DHCP assigns the correct IP. Then the clone is powered on.
#
# On vCenter: uses govc vm.clone (linked clone from snapshot).
# On standalone ESXi: vm.clone is unsupported, so we vmkfstools-copy the disk,
#   duplicate the source VMX with name/disk references rewritten, and register.
clone_vm() {
	local source_vm="$1"
	local clone_name="$2"
	local folder="${3:-${VC_FOLDER:-/Datacenter/vm/aba-e2e}}"
	local snapshot="${4:-${VM_SNAPSHOT:-aba-test}}"
	local power_on="${5:-yes}"

	echo "  Cloning VM: $source_vm -> $clone_name ..."

	if vm_exists "$clone_name"; then
		echo "  Destroying previous clone '$clone_name' ..."
		govc vm.power -off "$clone_name" || true
		govc vm.destroy "$clone_name" || true
	fi

	if _is_esxi; then
		# On ESXi, MACs are baked into the VMX before registration (govc
		# vm.network.change can't reference port groups invisible to the API).
		_clone_vm_esxi "$source_vm" "$clone_name" || return 1
	else
		_clone_vm_vcenter "$source_vm" "$clone_name" "$folder" "$snapshot" || return 1
		_clone_set_macs "$clone_name"
	fi
	_vm_annotate "$clone_name" "Cloned from $source_vm -- configuring"

	# Expand disk to target size
	if [ "${VM_DISK_SIZE:-0}" -gt 0 ]; then
		echo "  Setting disk size to ${VM_DISK_SIZE}GB ..."
		govc vm.disk.change -vm "$clone_name" -disk.label "Hard disk 1" -size "${VM_DISK_SIZE}G" || \
			echo "  WARNING: disk resize failed (non-fatal)"
	fi

	if [ "$power_on" = "no" ]; then
		echo "  Clone '$clone_name' ready (power-on deferred)."
	else
		echo "  Powering on clone '$clone_name' ..."
		govc vm.power -on "$clone_name" || true
		sleep "${VM_BOOT_DELAY:-8}"
		echo "  Clone '$clone_name' is booting."
	fi
}

# --- vCenter clone path (original logic) ------------------------------------
_clone_vm_vcenter() {
	local source_vm="$1" clone_name="$2" folder="$3" snapshot="$4"

	local ds_flag=""
	[ -n "${VM_DATASTORE:-}" ] && ds_flag="-ds=$VM_DATASTORE"

	local snap_flag=""
	if govc snapshot.tree -vm "$source_vm" 2>&1 | grep -v "^govc:" | grep -q .; then
		snap_flag="-snapshot=$snapshot"
	fi

	govc vm.clone -vm "$source_vm" $snap_flag \
		-folder "$folder" $ds_flag -on=false "$clone_name" || return 1
}

# --- ESXi clone path (vmkfstools + VMX copy + register) ---------------------
# Standalone ESXi does not support govc vm.clone. Instead:
#   1. Identify source VM's datastore, directory, current disk, and VMX.
#   2. vmkfstools -i (thin) to consolidate the snapshot chain into a single VMDK.
#   3. Copy the source VMX, rewriting VM name, disk filename, nvram, and
#      stripping snapshot/uuid metadata so ESXi treats it as a fresh VM.
#   4. govc vm.register to add the new VM to inventory.
_clone_vm_esxi() {
	local source_vm="$1" clone_name="$2"

	local target_ds="${VM_DATASTORE:-${GOVC_DATASTORE:-Datastore4-1}}"
	local esxi_host="$GOVC_URL"

	# Parse source VM's vmPathName: "[Datastore] dir/file.vmx"
	local src_vmpath
	src_vmpath=$(govc vm.info -json "$source_vm" \
		| python3 -c "
import json, sys
d = json.load(sys.stdin)
vms = d.get('virtualMachines', d.get('VirtualMachines', []))
if vms:
    print(vms[0]['config']['files']['vmPathName'])
") || true

	if [ -z "$src_vmpath" ]; then
		echo "  ERROR: cannot determine VMX path for '$source_vm'" >&2
		return 1
	fi

	local src_ds src_rel src_dir src_vmx_file src_vm_base
	src_ds=$(echo "$src_vmpath" | sed 's/^\[//;s/\].*//')
	src_rel=$(echo "$src_vmpath" | sed 's/^[^]]*\] //')
	src_dir=$(dirname "$src_rel")
	src_vmx_file=$(basename "$src_rel")
	src_vm_base="${src_vmx_file%.vmx}"

	# Get the current disk filename from the VMX (scsi0:0.fileName)
	local src_disk_file
	src_disk_file=$(ssh -o ConnectTimeout=10 "root@${esxi_host}" \
		"awk -F'\"' '/^scsi0:0.fileName/{print \$2}' '/vmfs/volumes/${src_ds}/${src_dir}/${src_vmx_file}'") || true
	if [ -z "$src_disk_file" ]; then
		echo "  ERROR: cannot read disk filename from source VMX" >&2
		return 1
	fi

	echo "  [esxi] source: [${src_ds}] ${src_dir}/${src_disk_file}"
	echo "  [esxi] target: [${target_ds}] ${clone_name}/${clone_name}.vmdk (thin)"

	# vmkfstools can't clone a locked VMDK; power off the source if needed.
	local _src_was_on=""
	local _src_power
	_src_power=$(govc vm.info -json "$source_vm" \
		| python3 -c "
import json, sys
d = json.load(sys.stdin)
vms = d.get('virtualMachines', d.get('VirtualMachines', []))
if vms: print(vms[0]['runtime']['powerState'])
") || true
	if [ "$_src_power" = "poweredOn" ]; then
		echo "  [esxi] powering off source VM '$source_vm' (vmkfstools requires unlocked disk) ..."
		govc vm.power -off "$source_vm" || true
		sleep 3
		_src_was_on=1
	fi

	# 1. Clone disk (consolidates snapshot chain)
	ssh "root@${esxi_host}" "
		rm -rf '/vmfs/volumes/${target_ds}/${clone_name}'
		mkdir -p '/vmfs/volumes/${target_ds}/${clone_name}'
		vmkfstools -i '/vmfs/volumes/${src_ds}/${src_dir}/${src_disk_file}' \
			'/vmfs/volumes/${target_ds}/${clone_name}/${clone_name}.vmdk' -d thin
	" 2>&1 | grep -v "^Clone:" || true

	# Power source back on if it was running before
	if [ -n "$_src_was_on" ]; then
		echo "  [esxi] restoring source VM '$source_vm' power state ..."
		govc vm.power -on "$source_vm" || true
	fi

	if ! ssh "root@${esxi_host}" \
		"test -f '/vmfs/volumes/${target_ds}/${clone_name}/${clone_name}.vmdk'"; then
		echo "  ERROR: disk clone failed" >&2
		return 1
	fi

	# 2. Copy VMX, rewriting name/disk/nvram, stripping stale metadata,
	#    and baking in MAC addresses from VM_CLONE_MACS.
	local _mac_entry="${VM_CLONE_MACS[$clone_name]:-}"
	local -a _macs=()
	[ -n "$_mac_entry" ] && _macs=($_mac_entry)

	# Build a sed script in a temp file to avoid quoting issues
	local _sed_script
	_sed_script=$(mktemp /tmp/clone-vmx-sed.XXXXXX)
	cat > "$_sed_script" <<-SEDEOF
		s|^displayName = .*|displayName = "${clone_name}"|
		s|^nvram = .*|nvram = "${clone_name}.nvram"|
		s|^scsi0:0.fileName = .*|scsi0:0.fileName = "${clone_name}.vmdk"|
		/^uuid\./d
		/^vc\./d
		/^sched\.swap\./d
		/^migrate\./d
		/^snapshot\./d
		/^checkpoint\./d
	SEDEOF

	local _mi
	for _mi in 0 1 2; do
		if [ $_mi -lt ${#_macs[@]} ] && [ -n "${_macs[$_mi]}" ]; then
			cat >> "$_sed_script" <<-MACEOF
				s|^ethernet${_mi}\.addressType = .*|ethernet${_mi}.addressType = "static"|
				s|^ethernet${_mi}\.address = .*|ethernet${_mi}.address = "${_macs[$_mi]}"|
				/^ethernet${_mi}\.generatedAddress/d
			MACEOF
			echo "  [esxi] ethernet-${_mi} MAC -> ${_macs[$_mi]}"
		fi
	done

	# Transform and write the VMX, then append any missing address lines
	ssh "root@${esxi_host}" "cat '/vmfs/volumes/${src_ds}/${src_dir}/${src_vmx_file}'" \
	| sed -f "$_sed_script" \
	| ssh "root@${esxi_host}" \
		"cat > '/vmfs/volumes/${target_ds}/${clone_name}/${clone_name}.vmx'"

	# The source VMX may use generatedAddress (vpx) instead of address (static).
	# After sed removes generatedAddress, we must ensure address lines exist.
	for _mi in 0 1 2; do
		if [ $_mi -lt ${#_macs[@]} ] && [ -n "${_macs[$_mi]}" ]; then
			if ! ssh "root@${esxi_host}" \
				"grep -q '^ethernet${_mi}\.address = ' '/vmfs/volumes/${target_ds}/${clone_name}/${clone_name}.vmx'"; then
				ssh "root@${esxi_host}" \
					"echo 'ethernet${_mi}.address = \"${_macs[$_mi]}\"' >> '/vmfs/volumes/${target_ds}/${clone_name}/${clone_name}.vmx'"
			fi
		fi
	done
	rm -f "$_sed_script"

	# 3. Copy nvram (firmware settings)
	ssh "root@${esxi_host}" \
		"cp '/vmfs/volumes/${src_ds}/${src_dir}/${src_vm_base}.nvram' \
		    '/vmfs/volumes/${target_ds}/${clone_name}/${clone_name}.nvram'" || true

	# 4. Register the VM
	govc vm.register -ds "${target_ds}" \
		"[${target_ds}] ${clone_name}/${clone_name}.vmx" 2>&1 || return 1

	echo "  [esxi] registered: ${clone_name}"
}

# --- Set MAC addresses on a clone's NICs -----------------------------------
_clone_set_macs() {
	local clone_name="$1"
	local mac_entry="${VM_CLONE_MACS[$clone_name]:-}"
	local -a macs=()
	if [ -n "$mac_entry" ]; then
		macs=($mac_entry)
	fi

	local i=0
	while true; do
		local device="ethernet-${i}"
		if ! govc device.info -vm "$clone_name" "$device" >/dev/null; then
			break
		fi
		local nic_net
		nic_net=$(_get_nic_network "$clone_name" "$device")
		if [ -z "$nic_net" ]; then
			[ $i -eq 0 ] && echo "  WARNING: Could not detect network for $device, using GOVC_NETWORK"
			nic_net="${GOVC_NETWORK:-Lab Network}"
		fi

		if [ $i -lt ${#macs[@]} ] && [ -n "${macs[$i]}" ]; then
			echo "  Setting $device MAC -> ${macs[$i]} (network: $nic_net)"
			govc vm.network.change -vm "$clone_name" -net "$nic_net" \
				-net.address "${macs[$i]}" "$device" || return 1
		else
			echo "  Setting $device MAC -> auto (network: $nic_net)"
			govc vm.network.change -vm "$clone_name" -net "$nic_net" \
				-net.address - "$device" || return 1
		fi
		i=$(( i + 1 ))
	done

	if [ $i -eq 0 ]; then
		echo "  WARNING: No NICs found on clone '$clone_name', skipping MAC setup."
	fi
}

# Power off and destroy a cloned VM. Safe to call on non-existent VMs.
destroy_vm() {
	local vm_name="$1"

	if vm_exists "$vm_name"; then
		echo "  Destroying VM '$vm_name' ..."
		govc vm.power -off "$vm_name" || true
		govc vm.destroy "$vm_name" || true
	else
		echo "  VM '$vm_name' does not exist, nothing to destroy."
	fi
}

# --- Ensure 3 NICs on a VM --------------------------------------------------
# Templates are built with 1 NIC (Lab Network). The E2E framework needs 3:
#   ethernet-0 / ens192 = Lab Network      (lab, DHCP)
#   ethernet-1 / ens224 = Private Network  (VLAN trunk)
#   ethernet-2 / ens256 = External Network (internet)
# Adds any missing NICs. Safe to call on VMs that already have 3 NICs.

_vm_ensure_3nics() {
	local vm_name="$1"
	local nic2_net="${VM_NIC2_NETWORK:-Private Network}"
	local nic3_net="${VM_NIC3_NETWORK:-External Network}"

	local nic_count=0
	while govc device.info -vm "$vm_name" "ethernet-${nic_count}" >/dev/null; do
		nic_count=$(( nic_count + 1 ))
	done

	if [ "$nic_count" -ge 3 ]; then
		echo "  [vm] $vm_name already has $nic_count NICs -- skipping"
		return 0
	fi

	echo "  [vm] $vm_name has $nic_count NIC(s) -- adding $(( 3 - nic_count )) more ..."

	if [ "$nic_count" -lt 2 ]; then
		if ! govc vm.network.add -vm "$vm_name" -net "$nic2_net" -net.adapter vmxnet3; then
			echo "  [vm]   WARNING: govc vm.network.add failed for $nic2_net (ESXi port group not visible via API?)"
			_esxi_add_nic_via_vmx "$vm_name" 1 "$nic2_net" || return 1
		fi
		echo "  [vm]   ethernet-1 -> $nic2_net"
	fi
	if [ "$nic_count" -lt 3 ]; then
		if ! govc vm.network.add -vm "$vm_name" -net "$nic3_net" -net.adapter vmxnet3; then
			echo "  [vm]   WARNING: govc vm.network.add failed for $nic3_net (ESXi port group not visible via API?)"
			_esxi_add_nic_via_vmx "$vm_name" 2 "$nic3_net" || return 1
		fi
		echo "  [vm]   ethernet-2 -> $nic3_net"
	fi
}

# Add a NIC by directly editing the VMX on ESXi (fallback when govc can't see the port group).
_esxi_add_nic_via_vmx() {
	local vm_name="$1" nic_idx="$2" net_name="$3"
	_is_esxi || { echo "  ERROR: _esxi_add_nic_via_vmx only works on ESXi" >&2; return 1; }

	local esxi_host="$GOVC_URL"
	local vmx_path
	vmx_path=$(govc vm.info -json "$vm_name" \
		| python3 -c "
import json, sys
d = json.load(sys.stdin)
vms = d.get('virtualMachines', d.get('VirtualMachines', []))
if vms: print(vms[0]['config']['files']['vmPathName'])
") || return 1

	local ds rel
	ds=$(echo "$vmx_path" | sed 's/^\[//;s/\].*//')
	rel=$(echo "$vmx_path" | sed 's/^[^]]*\] //')

	local pci_slot=$(( 192 + nic_idx * 32 ))
	ssh "root@${esxi_host}" "cat >> '/vmfs/volumes/${ds}/${rel}'" <<-NICEOF
		ethernet${nic_idx}.virtualDev = "vmxnet3"
		ethernet${nic_idx}.networkName = "${net_name}"
		ethernet${nic_idx}.addressType = "generated"
		ethernet${nic_idx}.uptCompatibility = "TRUE"
		ethernet${nic_idx}.present = "TRUE"
		ethernet${nic_idx}.pciSlotNumber = "${pci_slot}"
	NICEOF
	# Reload the VMX so ESXi picks up the changes
	govc vm.unregister "$vm_name" || true
	govc vm.register -ds "$ds" "[${ds}] ${rel}" || return 1
}

# --- VM Template Configuration ----------------------------------------------

declare -A VM_TEMPLATES=(
	[rhel8]="aba-e2e-template-rhel8"
	[rhel9]="aba-e2e-template-rhel9"
	[rhel10]="aba-e2e-template-rhel10"
)

# MAC addresses per clone (set via config.env, declared here if not already)
if ! declare -p VM_CLONE_MACS >/dev/null; then
	declare -A VM_CLONE_MACS=()
fi

VM_DEFAULT_USER="${VM_DEFAULT_USER:-steve}"

# SSH wrappers: use _essh/_escp from remote.sh (sourced above).
# vm-ops.sh no longer defines its own -- remote.sh is canonical for bastion-side.
# framework.sh defines a separate runner-side _essh with different options.
