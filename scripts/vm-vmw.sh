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
	govc vm.power -on "$vm"
}

vmp_power_off() {
	local vm=$1
	aba_debug "Running: govc vm.power -s $vm"
	govc vm.power -s "$vm" || true
}

vmp_kill() {
	local vm=$1
	aba_debug "Running: govc vm.power -off $vm"
	govc vm.power -off "$vm" || true
}
