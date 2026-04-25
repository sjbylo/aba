#!/bin/bash 
# Stop the VMs gracefully with vmware system shutdown

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

if [ "$ask" ]; then
	echo
	for name in $hosts; do
		vm=$(vm_name "$CLUSTER_NAME" "$name")
		[ "$VC" ] && echo $cluster_folder/$vm || echo $vm
	done

	ask "Stop the above virtual machine(s)" || exit 1
fi

for name in $hosts; do
	exec_cmd="govc vm.power -s $(vm_name "$CLUSTER_NAME" "$name")"
	aba_debug "Running: $exec_cmd"
	$exec_cmd || true
done

# Return 0 when every VM in $hosts is poweredOff (aligned with cluster-graceful-shutdown aba_wait_show).
_vmw_stop_all_powered_off() {
	local name vm_info power_state
	for name in $hosts; do
		aba_debug "Running: govc vm.info -json $(vm_name "$CLUSTER_NAME" "$name")"
		vm_info=$(govc vm.info -json "$(vm_name "$CLUSTER_NAME" "$name")")
		[ ! "$vm_info" ] && return 1
		power_state=$(echo "$vm_info" | jq -r '.virtualMachines[0].runtime.powerState')
		[ "$power_state" = "null" ] && return 1
		[ "$power_state" = "poweredOn" ] && return 1
	done
	return 0
}

if [ "$wait" ]; then
	_wait_mins=40
	_wait_timeout=$(( 60 * _wait_mins ))
	_wait_rc=0
	aba_wait_show "Waiting for VMs to power off (Ctrl-C to abort)" 10 "$_wait_timeout" \
		_vmw_stop_all_powered_off || _wait_rc=$?
	if [ "$_wait_rc" -eq 130 ] || [ "$_wait_rc" -eq 143 ]; then
		aba_info "Aborted. VMs may still be shutting down in the background."
	elif [ "$_wait_rc" -ne 0 ]; then
		aba_abort "Timed out after ${_wait_timeout}s waiting for VMs to power off"
	fi
fi

exit 0
