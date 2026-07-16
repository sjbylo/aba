#!/bin/bash
# VM provider adapter: VMware vSphere / ESXi (via govc).
#
# Sourced by the VM driver (scripts/vm-provider.sh) and by the vmw-*.sh shims.
# Defines the vmp_* primitive contract -- the genuinely platform-specific calls.
# All shared lifecycle logic (config resolution, host iteration, confirmation,
# waiting) lives in the driver, NOT here.
#
# Primitive contract (every adapter must define these):
#   vmp_exists <vm>        exit 0 if the VM exists
#   vmp_is_on <vm>         exit 0 if the VM is powered on / running
#   vmp_info  <vm>         print "<numCPU> <memoryGB> <state>" or exit non-zero
#   vmp_power_on  <vm>     start the VM (idempotent)
#   vmp_power_off <vm>     graceful shutdown request
#   vmp_kill      <vm>     immediate power off
#
# All primitives take a fully-resolved VM name (see vm_name in include_all.sh)
# and rely on govc environment from vmware.conf.

# Retry a govc command on transient vCenter errors (task conflicts, locks, etc.).
# Waits with linear backoff (5s, 10s, 15s, 20s, 25s) for up to ~75s total.
_govc_retry() {
	try_cmd -n 5 -d 5 -D 5 -m "govc $1" -- govc "$@"
}

# Cached lookup of a VM's runtime+hardware as JSON; empty on lookup failure.
_vmw_vm_json() {
	govc vm.info -json "$1" 2>/dev/null
}

vmp_exists() {
	local vm=$1 ps
	aba_debug "Running: govc vm.info -json $vm"
	ps=$(_vmw_vm_json "$vm" | jq -r '.virtualMachines[0].runtime.powerState')
	[ "$ps" != "null" ] && [ -n "$ps" ]
}

vmp_is_on() {
	local vm=$1 ps
	aba_debug "Running: govc vm.info -json $vm"
	ps=$(_vmw_vm_json "$vm" | jq -r '.virtualMachines[0].runtime.powerState')
	[ "$ps" = "poweredOn" ]
}

# Print "<numCPU> <memoryGB> <state>" for an existing VM; non-zero if absent.
vmp_info() {
	local vm=$1 json ps num_cpu memory_mb memory_gb
	aba_debug "Running: govc vm.info -json $vm"
	json=$(_vmw_vm_json "$vm")
	[ "$json" ] || return 1
	ps=$(echo "$json" | jq -r '.virtualMachines[0].runtime.powerState')
	[ "$ps" = "null" ] && return 1
	num_cpu=$(echo "$json" | jq -r '.virtualMachines[0].config.hardware.numCPU')
	memory_mb=$(echo "$json" | jq -r '.virtualMachines[0].config.hardware.memoryMB')
	[ "$memory_mb" ] && [ "$memory_mb" != "null" ] && memory_gb=$(( memory_mb / 1024 )) || memory_gb="?"
	echo "$num_cpu ${memory_gb}GB $ps"
}

vmp_power_on() {
	local vm=$1
	# Skip when already on -- avoids govc "current state (Powered on)" error.
	vmp_is_on "$vm" && return 0
	aba_debug "Running: govc vm.power -on $vm"
	_govc_retry vm.power -on "$vm"
}

vmp_power_off() {
	local vm=$1
	aba_debug "Running: govc vm.power -s $vm"
	_govc_retry vm.power -s "$vm" || true
}

vmp_kill() {
	local vm=$1
	aba_debug "Running: govc vm.power -off $vm"
	_govc_retry vm.power -off "$vm" || true
}

# ---------------------------------------------------------------------------
# Higher-level reusable primitives (create / upload / attach / destroy)
# ---------------------------------------------------------------------------

# Upload a local ISO to a vSphere datastore.
#   vmp_upload_iso <local_iso> <datastore> <remote_path>
vmp_upload_iso() {
	local local_iso=$1 datastore=$2 remote_path=$3
	local ret=0

	[ -f "$local_iso" ] || { echo "vmp_upload_iso: local ISO not found: $local_iso" >&2; return 1; }

	aba_debug "Running: govc datastore.upload -ds $datastore $local_iso $remote_path"
	if [ "${PLAIN_OUTPUT:-}" ]; then
		cat "$local_iso" | govc datastore.upload -ds "$datastore" - "$remote_path" || ret=$?
	else
		govc datastore.upload -ds "$datastore" "$local_iso" "$remote_path" || ret=$?
	fi

	if [ $ret -ne 0 ]; then
		echo "vmp_upload_iso: upload failed (rc=$ret)" >&2
		return $ret
	fi

	local remote_size
	remote_size=$(govc datastore.ls -ds "$datastore" -l "$remote_path" 2>/dev/null | awk '{print $1}')
	if [ "$remote_size" = "0B" ] || [ -z "$remote_size" ]; then
		echo "vmp_upload_iso: post-upload verification failed -- ISO on datastore is 0 bytes or missing" >&2
		return 1
	fi
}

# Create a VM with UEFI firmware, vmxnet3 NIC, secure boot, hot-add, and disks.
#   vmp_create_vm <vm_name> <cpu> <mem_gb> <mac> <datastore> <network> <folder> <nested_hv> [data_disk_gb]
vmp_create_vm() {
	local vm_name=$1 cpu=$2 mem_gb=$3 mac=$4 datastore=$5 network=$6 folder=$7 nested_hv=$8
	local data_disk_gb=${9:-}

	aba_debug "vmp_create_vm: $vm_name ${cpu}C/${mem_gb}G mac=$mac ds=$datastore net=$network folder=$folder nested=$nested_hv data_disk=${data_disk_gb:-none}"

	govc vm.create \
		-version vmx-15 \
		-g rhel8_64Guest \
		-firmware=efi \
		-c="$cpu" \
		-m=$(( mem_gb * 1024 )) \
		-net="$network" \
		-net.adapter vmxnet3 \
		-net.address="$mac" \
		-disk-datastore="$datastore" \
		-folder="$folder" \
		-on=false \
		"$vm_name"

	govc device.boot -secure -vm "$vm_name"

	govc vm.change -vm "$vm_name" \
		-e disk.enableUUID=TRUE \
		-cpu-hot-add-enabled=true \
		-memory-hot-add-enabled=true \
		-nested-hv-enabled="$nested_hv"

	aba_debug "vmp_create_vm: attaching 120GB OS disk on [$datastore]"
	govc vm.disk.create \
		-vm "$vm_name" \
		-name "$vm_name/$vm_name" \
		-size 120GB \
		-thick=false \
		-ds="$datastore"

	if [ -n "$data_disk_gb" ]; then
		aba_debug "vmp_create_vm: attaching ${data_disk_gb}GB data disk on [$datastore]"
		govc vm.disk.create \
			-vm "$vm_name" \
			-name "$vm_name/${vm_name}_data" \
			-size "${data_disk_gb}GB" \
			-thick=false \
			-ds="$datastore"
	fi
}

# Attach an ISO to a VM via explicit cdrom.add + cdrom.insert (3 retries).
#   vmp_attach_iso <vm_name> <iso_datastore> <iso_path>
vmp_attach_iso() {
	local vm_name=$1 iso_datastore=$2 iso_path=$3
	local _cdrom_out _cdrom_dev _rc

	_cdrom_out=$(govc device.cdrom.add -vm "$vm_name" 2>&1)
	_rc=$?
	_cdrom_dev=$(echo "$_cdrom_out" | grep -o 'cdrom-[0-9]*')
	aba_debug "vmp_attach_iso: cdrom.add vm=$vm_name rc=$_rc dev=$_cdrom_dev out=$_cdrom_out"

	if [ $_rc -ne 0 ] || [ -z "$_cdrom_dev" ]; then
		echo "vmp_attach_iso: failed to add CD-ROM on $vm_name: $_cdrom_out" >&2
		return 1
	fi

	if ! try_cmd -n 3 -d 3 -m "Insert ISO on $vm_name" -- \
		govc device.cdrom.insert -vm "$vm_name" -device "$_cdrom_dev" \
			-ds "$iso_datastore" "$iso_path"; then
		return 1
	fi

	local _verify_out
	_verify_out=$(govc device.info -json -vm "$vm_name" "$_cdrom_dev" 2>&1) || true
	if ! echo "$_verify_out" | grep -q '"startConnected": true'; then
		echo "vmp_attach_iso: WARNING -- startConnected is NOT true on $vm_name $_cdrom_dev after insert" >&2
	fi
}

# Destroy a VM and verify it no longer exists.
#   vmp_destroy <vm_name>
vmp_destroy() {
	local vm=$1 power_state
	aba_debug "Running: govc vm.destroy $vm"
	_govc_retry vm.destroy "$vm" || true

	power_state=$(govc vm.info -json "$vm" 2>&1 | jq -r '.virtualMachines[0].runtime.powerState')
	if [ "$power_state" != "null" ] && [ -n "$power_state" ]; then
		echo "vmp_destroy: VM $vm still exists after destroy (state=$power_state)" >&2
		return 1
	fi
}
