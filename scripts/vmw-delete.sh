#!/bin/bash 
# Delete all VMs in the cluster, as defined by agent config files

source scripts/include_all.sh

### scripts/install-govc.sh

[ "$1" ] && set -x

if [ -s vmware.conf ]; then
	source <(normalize-vmware-conf)  # This is needed for $VC_FOLDER variable
else
	echo "vmware.conf file not defined. Run 'aba vmw' to create it if needed"

	exit 0
fi


if [ ! "$CLUSTER_NAME" ]; then
	scripts/cluster-config-check.sh
	eval `scripts/cluster-config.sh || exit 1`
fi

source <(normalize-aba-conf)  # Fetch the 'ask' param

verify-aba-conf || exit 1

cluster_folder=$VC_FOLDER/$CLUSTER_NAME

# If at least one VM exists, then show vms.
if scripts/vmw-exists.sh; then
	# Only show list of existing vms if ask=1
	if [ "$ask" ]; then
		for name in $CP_NAMES $WORKER_NAMES; do
			[ "$VC" ] && echo $cluster_folder/${CLUSTER_NAME}-$name || echo ${CLUSTER_NAME}-$name
		done
	fi
else
	# No VMs
	exit 1
fi

ask "Delete the above virtual machine(s)" || exit 1

for name in $CP_NAMES $WORKER_NAMES; do
	echo Destroy VM ${CLUSTER_NAME}-$name
	govc vm.destroy ${CLUSTER_NAME}-$name || true
done

if [ "$VC" ]; then
	echo Deleting cluster folder $cluster_folder
	govc object.destroy $cluster_folder || true
fi

exit 0

