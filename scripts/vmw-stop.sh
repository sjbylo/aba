#!/bin/bash -e

. scripts/include_all.sh

#[ ! "$1" ] && echo Usage: `basename $0` --dir directory && exit 1
[ "$1" ] && set -x

if [ ! "$CLUSTER_NAME" ]; then
	eval `scripts/cluster-config.sh || exit 1`
fi

#bin/init.sh $@

. vmware.conf

for name in $WORKER_NAMES $CP_NAMES; do
	# Shut down guest if vmware tools exist
	govc vm.power -s ${CLUSTER_NAME}-$name  
	
done

