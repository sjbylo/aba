#!/bin/bash 
# Start the VMs

source scripts/include_all.sh

aba_debug "Running: $0 $*" >&2

. <(process_args $*)
# eval all key value args
. <(echo $* | tr " " "\n")

if [ -s vmware.conf ]; then
	source <(normalize-vmware-conf)  # This is needed for $VC_FOLDER
else
	aba_info "vmware.conf file not defined. Run 'aba vmw' to create it if needed"
	exit 0
fi

if [ ! "$CLUSTER_NAME" ]; then
	scripts/cluster-config-check.sh
	eval `scripts/cluster-config.sh || exit 1`
fi

source <(normalize-aba-conf)  # Fetch the 'ask' param

verify-aba-conf || aba_abort "$_ABA_CONF_ERR"

cluster_folder=$VC_FOLDER/$CLUSTER_NAME

hosts="$WORKER_NAMES $CP_NAMES"
[ "$workers" ] && hosts="$WORKER_NAMES"
[ "$masters" ] && hosts="$CP_NAMES"
[ ! "$hosts" ] && hosts="$CP_NAMES"

# If at least one VM exists, then show vms.
if scripts/vmw-exists.sh; then
	for name in $hosts; do
		vm=$(vm_name "$CLUSTER_NAME" "$name")
		[ "$VC" ] && echo $cluster_folder/$vm || echo $vm
	done

	ask "Start the above virtual machine(s)" || exit 1
else
	exit 1
fi

for name in $hosts ; do
	vm_path="$(vm_name "$CLUSTER_NAME" "$name")"
	# Skip power-on when already on -- avoids govc "cannot be performed in the current state (Powered on)"
	aba_debug "Running: govc vm.info -json $vm_path"
	power_state=$(govc vm.info -json "$vm_path" | jq -r '.virtualMachines[0].runtime.powerState')
	if [ "$power_state" != "poweredOn" ]; then
		exec_cmd="govc vm.power -on $vm_path"
		aba_debug "Running: $exec_cmd"
		$exec_cmd
	fi
done

# Return 0 when every VM in $hosts is poweredOn (optional wait after start).
_vmw_start_all_powered_on() {
	local name vm_path power_state
	for name in $hosts; do
		vm_path="$(vm_name "$CLUSTER_NAME" "$name")"
		aba_debug "Running: govc vm.info -json $vm_path"
		power_state=$(govc vm.info -json "$vm_path" | jq -r '.virtualMachines[0].runtime.powerState')
		[ "$power_state" = "poweredOn" ] || return 1
	done
	return 0
}

if [ "$wait" ]; then
	_wait_mins=40
	_wait_timeout=$(( 60 * _wait_mins ))
	if ! aba_wait_show "Waiting for VMs to power on" 10 "$_wait_timeout" \
		_vmw_start_all_powered_on; then
		aba_abort "Timed out after ${_wait_timeout}s waiting for VMs to power on"
	fi
fi

exit 0 

