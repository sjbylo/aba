#!/bin/bash 

source scripts/include_all.sh

[ "$1" ] && set -x

scripts/install-govc.sh

if [ ! "$CLUSTER_NAME" ]; then
	eval `scripts/cluster-config.sh || exit 1`
fi

source vmware.conf

for name in $WORKER_NAMES $CP_NAMES ; do
	govc vm.power -on ${CLUSTER_NAME}-$name
done

