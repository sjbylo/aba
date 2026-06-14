#!/bin/bash
# VM provider adapter: KVM / libvirt (via virsh).
#
# Sourced by the VM driver (scripts/vm-provider.sh) and by the kvm-*.sh shims.
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
# and rely on $LIBVIRT_URI being set from kvm.conf.

vmp_exists() {
	local vm=$1
	aba_debug "Running: virsh -c $LIBVIRT_URI dominfo $vm"
	virsh -c "$LIBVIRT_URI" dominfo "$vm" >/dev/null 2>&1
}

vmp_is_on() {
	local vm=$1 state
	aba_debug "Running: virsh -c $LIBVIRT_URI domstate $vm"
	state=$(virsh -c "$LIBVIRT_URI" domstate "$vm" 2>/dev/null)
	[ "$state" = "running" ]
}

# Print "<numCPU> <memoryGB> <state>" for an existing VM; non-zero if absent.
vmp_info() {
	local vm=$1 info state num_cpu memory_kb memory_gb
	aba_debug "Running: virsh -c $LIBVIRT_URI dominfo $vm"
	info=$(virsh -c "$LIBVIRT_URI" dominfo "$vm" 2>/dev/null) || return 1
	state=$(echo "$info" | awk '/^State:/ {$1=""; s=substr($0,2); gsub(/ /,"-",s); print s}')
	num_cpu=$(echo "$info" | awk '/^CPU\(s\):/ {print $2}')
	memory_kb=$(echo "$info" | awk '/^Max memory:/ {print $3}')
	[ "$memory_kb" ] && memory_gb=$(( memory_kb / 1048576 )) || memory_gb="?"
	echo "$num_cpu ${memory_gb}GB $state"
}

vmp_power_on() {
	local vm=$1
	aba_debug "Running: virsh -c $LIBVIRT_URI start $vm"
	virsh -c "$LIBVIRT_URI" start "$vm" 2>/dev/null || true
}

vmp_power_off() {
	local vm=$1
	aba_debug "Running: virsh -c $LIBVIRT_URI shutdown $vm"
	virsh -c "$LIBVIRT_URI" shutdown "$vm" 2>/dev/null || true
}

vmp_kill() {
	local vm=$1
	aba_debug "Running: virsh -c $LIBVIRT_URI destroy $vm"
	virsh -c "$LIBVIRT_URI" destroy "$vm" || true
}
