#!/bin/bash 

source scripts/include_all.sh

scripts/install-govc.sh

[ "$1" ] && set -x

if [ ! "$CLUSTER_NAME" ]; then
	eval `scripts/cluster-config.sh || exit 1`
fi

source vmware.conf

for name in $WORKER_NAMES $CP_NAMES; do
	# Shut down guest if vmware tools exist
	govc vm.power -s ${CLUSTER_NAME}-$name  
	
done

