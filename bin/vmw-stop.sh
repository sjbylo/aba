#!/bin/bash -e

[ ! "$1" ] && echo Usage: `basename $0` --dir directory && exit 1
[ "$DEBUG_ABA" ] && set -x

if [ ! "$CLUSTER_NAME" ]; then
	eval `common/scripts/cluster-config.sh $@ || exit 1`
fi

bin/init.sh $@

. ~/.vmware.conf

for name in $WORKER_NAMES $CP_NAMES; do
	# Shut down guest if vmware tools exist
	govc vm.power -s ${CLUSTER_NAME}-$name  ### || govc vm.power -off ${CLUSTER_NAME}-$name 
	
done

