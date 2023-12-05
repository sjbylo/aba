#!/bin/bash 

. scripts/include_all.sh

scripts/install-govc.sh

[ "$1" ] && set -x

if [ ! "$CLUSTER_NAME" ]; then
	eval `scripts/cluster-config.sh || exit 1`
fi

source vmware.conf 

for name in $CP_NAMES $WORKER_NAMES; do
	echo Destroy VM ${CLUSTER_NAME}-$name
	govc vm.destroy ${CLUSTER_NAME}-$name || true
done

if [ "$VC" ]; then
	echo govc object.destroy $FOLDER
	govc object.destroy $FOLDER || true
fi

