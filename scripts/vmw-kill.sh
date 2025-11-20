#!/bin/bash 
# Power off the VMs immediatelly 

source scripts/include_all.sh



if [ -s vmware.conf ]; then
	source <(normalize-vmware-conf)  # This is needed for $VC_FOLDER
else
	echo "vmware.conf file not defined. Run 'aba vmw' to create it if needed."
	exit 0
fi

if [ ! "$CLUSTER_NAME" ]; then
	scripts/cluster-config-check.sh
	eval `scripts/cluster-config.sh || exit 1`
fi

source <(normalize-aba-conf)  # Fetch the 'ask' param

verify-aba-conf || exit 1

cluster_folder=$VC_FOLDER/$CLUSTER_NAME

if [ "$ask" ]; then
	echo
	for name in $CP_NAMES $WORKER_NAMES; do
		[ "$VC" ] && echo $cluster_folder/${CLUSTER_NAME}-$name || echo ${CLUSTER_NAME}-$name
	done

	ask "Immediately power down the above virtual machine(s)" || exit 1
fi

for name in $CP_NAMES $WORKER_NAMES; do
	govc vm.power -off ${CLUSTER_NAME}-$name || true 
done

exit 0
