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
	# No VMs
	exit 1
fi

ask "Delete the above virtual machine(s)" || exit 1

for name in $CP_NAMES $WORKER_NAMES; do
	vm=$(vm_name "$CLUSTER_NAME" "$name")
	aba_info Destroy VM $vm
	govc vm.destroy $vm || true  # FIXME: should check first if the VM exists and only then delete instead of using || true
done

if [ "$VC" ]; then
	aba_info Deleting cluster folder $cluster_folder
	govc object.destroy $cluster_folder || true
fi

exit 0

