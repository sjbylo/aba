#!/bin/bash 

source scripts/include_all.sh

[ "$1" ] && set -x

if [ -s vmware.conf ]; then
	source <(normalize-vmware-conf)  # This is needed for $VC_FOLDER
else
	echo "vmware.conf file not defined. Run 'make vmw' to create it if needed"
	exit 0
fi

if [ ! "$CLUSTER_NAME" ]; then
	scripts/cluster-config-check.sh
	eval `scripts/cluster-config.sh || exit 1`
fi

source <(normalize-aba-conf)  # Fetch the 'ask' param

# If at least one VM exists, then show vms.
if scripts/vmw-vm-exists.sh; then
	for name in $CP_NAMES $WORKER_NAMES; do
		[ "$VC" ] && echo $VC_FOLDER/${CLUSTER_NAME}-$name || echo ${CLUSTER_NAME}-$name
	done

	ask "Start the above virtual machine(s)" || exit 1
else
	exit 1
fi

for name in $WORKER_NAMES $CP_NAMES ; do
	govc vm.power -on ${CLUSTER_NAME}-$name
done

