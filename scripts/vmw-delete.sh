#!/bin/bash 

source scripts/include_all.sh

scripts/install-govc.sh

[ "$1" ] && set -x

if [ -s vmware.conf ]; then
	source <(normalize-vmware-conf)  # This is needed for $VMW_FOLDER variable
else
	echo "vmware.conf file not defined. Run 'make vmw' to create it if needed"
	exit 0
fi


if [ ! "$CLUSTER_NAME" ]; then
	scripts/cluster-config-check.sh
	eval `scripts/cluster-config.sh || exit 1`
fi

source <(normalize-aba-conf)

if [ "$ask" ]; then
	echo
	for name in $CP_NAMES $WORKER_NAMES; do
		[ "$VC" ] && echo $FOLDER/${CLUSTER_NAME}-$name || echo ${CLUSTER_NAME}-$name
	done

	ask "Delete the above virtual machines(s)" || exit 1
fi

for name in $CP_NAMES $WORKER_NAMES; do
	echo Destroy VM ${CLUSTER_NAME}-$name
	govc vm.destroy ${CLUSTER_NAME}-$name || true
done

if [ "$VC" ]; then
	echo govc object.destroy $FOLDER
	govc object.destroy $FOLDER || true
fi

