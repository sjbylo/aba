#!/bin/bash 
# Delete all VMs in the cluster, as defined by agent config files

source scripts/include_all.sh


if [ -s vmware.conf ]; then
	source <(normalize-vmware-conf)  # This is needed for $VC_FOLDER variable
else
	aba_info "vmware.conf file not defined. Run 'aba vmw' to create it if needed"
	exit 0
fi


if [ ! "$CLUSTER_NAME" ]; then
	if [ ! -s install-config.yaml ] || [ ! -s agent-config.yaml ]; then
		aba_info "Cluster config files missing -- nothing to delete"
		exit 0
	fi
	scripts/cluster-config-check.sh
	eval `scripts/cluster-config.sh || exit 1`
fi

source <(normalize-aba-conf)  # Fetch the 'ask' param

verify-aba-conf || aba_abort "$_ABA_CONF_ERR"

cluster_folder=$VC_FOLDER/$CLUSTER_NAME

# If at least one VM exists, then show vms.
if scripts/vmw-exists.sh; then
	# Only show list of existing vms if ask=1
	if [ "$ask" ]; then
		for name in $CP_NAMES $WORKER_NAMES; do
			vm=$(vm_name "$CLUSTER_NAME" "$name")
			[ "$VC" ] && echo $cluster_folder/$vm || echo $vm
		done
	fi
else
	aba_info "No VMs found -- nothing to delete"
	exit 0
fi

ask "Delete the above virtual machine(s)" || exit 1

for name in $CP_NAMES $WORKER_NAMES; do
	vm=$(vm_name "$CLUSTER_NAME" "$name")
	aba_debug "Running: govc vm.info -json $vm"
	power_state=$(govc vm.info -json "$vm" 2>&1 | jq -r '.virtualMachines[0].runtime.powerState')
	if [ "$power_state" = "null" ]; then
		aba_info "VM $vm does not exist (skipping)"
		continue
	fi
	aba_info "Destroy VM $vm (was $power_state)"
	exec_cmd="govc vm.destroy $vm"
	aba_debug "Running: $exec_cmd"
	$exec_cmd || true
	aba_debug "Running: govc vm.info -json $vm (verify)"
	power_state=$(govc vm.info -json "$vm" 2>&1 | jq -r '.virtualMachines[0].runtime.powerState')
	[ "$power_state" != "null" ] && aba_abort "VM $vm still exists after destroy (state=$power_state)"
done

if [ "$VC" ]; then
	# Only destroy the cluster folder if it exists and is empty (VMs already removed above)
	aba_debug "Running: govc object.collect -s $cluster_folder name"
	if govc object.collect -s "$cluster_folder" name >/dev/null 2>&1; then
		aba_info "Deleting cluster folder $cluster_folder"
		exec_cmd="govc object.destroy $cluster_folder"
		aba_debug "Running: $exec_cmd"
		$exec_cmd || true
	fi
fi

exit 0

