#!/bin/bash 
# Delete all VMs in the cluster, as defined by agent config files

source scripts/include_all.sh

ensure_govc

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
	eval "$(scripts/cluster-config.sh)" || exit 1
fi

source <(normalize-aba-conf)  # Fetch the 'ask' param

verify-aba-conf || aba_abort "$_ABA_CONF_ERR"

cluster_folder=$VC_FOLDER/$CLUSTER_NAME

# If at least one VM exists, then show vms.
# Capture via || so the ERR trap does not treat "no VMs" (exit 1) as fatal.
_exists_rc=0
scripts/vmw-exists.sh || _exists_rc=$?
if [ $_exists_rc -eq 2 ]; then
	aba_abort "Cannot reach vCenter — refusing to skip VM cleanup (VMs may still exist)"
elif [ $_exists_rc -ne 0 ]; then
	aba_info "No VMs found -- nothing to delete"
	exit 0
else
	# Only show list of existing vms if ask=1
	if [ "$ask" ]; then
		for name in $CP_NAMES $WORKER_NAMES; do
			vm=$(vm_name "$CLUSTER_NAME" "$name")
			[ "$VC" ] && echo $cluster_folder/$vm || echo $vm
		done
	fi
fi

ask -n --auto-yes "Delete the above virtual machine(s)" || exit 1

source scripts/vm-vmw.sh

for name in $CP_NAMES $WORKER_NAMES; do
	vm=$(vm_name "$CLUSTER_NAME" "$name")
	_ex=0
	vmp_exists "$vm" || _ex=$?
	if [ $_ex -gt 1 ]; then
		aba_abort "Cannot reach vCenter — cannot verify VM $vm"
	elif [ $_ex -ne 0 ]; then
		aba_info "VM $vm does not exist (skipping)"
		continue
	fi
	aba_info "Destroy VM $vm"
	vmp_destroy "$vm" || aba_abort "VM $vm still exists after destroy"
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

