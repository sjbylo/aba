#!/bin/bash
# Power off the VMs immediately

source scripts/include_all.sh

aba_debug "Running: $0 $*" >&2

. <(process_args $*)
. <(echo $* | tr " " "\n")

if [ -s vmware.conf ]; then
	ensure_govc
	source <(normalize-vmware-conf)  # This is needed for $VC_FOLDER
else
	aba_info "vmware.conf file not defined. Run 'aba vmw' to create it if needed"
	exit 0
fi

if [ ! "$CLUSTER_NAME" ]; then
	scripts/cluster-config-check.sh
	eval "$(scripts/cluster-config.sh)" || exit 1
fi

source <(normalize-aba-conf)  # Fetch the 'ask' param

verify-aba-conf || aba_abort "$_ABA_CONF_ERR"

cluster_folder=$VC_FOLDER/$CLUSTER_NAME

_select_vm_hosts

_running_vms=$(vmw_running_vms $hosts)

if [ -z "$_running_vms" ]; then
	aba_info "All VMs are already powered off"
	exit 0
fi

if [ "$ask" ]; then
	echo
	for name in $_running_vms; do
		vm=$(vm_name "$CLUSTER_NAME" "$name")
		[ "$VC" ] && echo $cluster_folder/$vm || echo $vm
	done

	ask "Immediately power down the above virtual machine(s)" || exit 1
fi

for name in $hosts; do
	exec_cmd="govc vm.power -off $(vm_name "$CLUSTER_NAME" "$name")"
	aba_debug "Running: $exec_cmd"
	$exec_cmd || true
done

exit 0
