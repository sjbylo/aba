#!/bin/bash -e

[ ! "$1" ] && echo Usage: `basename $0` --dir directory && exit 1
[ "$DEBUG_ABA" ] && set -x

common/scripts/validate.sh $@

if [ ! "$CLUSTER_NAME" ]; then
	eval `common/scripts/cluster-config.sh $@ || exit 1`
fi

. ~/.vmware.conf

for name in $CP_NAMES ; do
	govc vm.power -off ${CLUSTER_NAME}-$name
done

i=1
for name in $WORKER_NAMES ; do
	govc vm.power -off ${CLUSTER_NAME}-$name
done

