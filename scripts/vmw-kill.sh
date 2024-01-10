#!/bin/bash 

. scripts/include_all.sh

####scripts/install-govc.sh

[ "$1" ] && set -x

if [ -s vmware.conf ]; then
	source vmware.conf  # This is needed for $VMW_FOLDER
else
	echo "vmware.conf file not defined. Run 'make vmw' to create it if needed"
	exit 0
fi

if [ ! "$CLUSTER_NAME" ]; then
	scripts/cluster-config-check.sh
	eval `scripts/cluster-config.sh || exit 1`
fi

for name in $CP_NAMES $WORKER_NAMES; do
	govc vm.power -off ${CLUSTER_NAME}-$name || true
done

