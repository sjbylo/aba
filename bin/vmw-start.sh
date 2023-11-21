#!/bin/bash -e

[ ! "$1" ] && echo "Usage: `basename $0` --dir <directory>" && exit 1

common/scripts/validate.sh $@

if [ ! "$CLUSTER_NAME" ]; then
	eval `common/scripts/cluster-config.sh $@ || exit 1`
fi

. ~/.vmware.conf

for name in $WORKER_NAMES $CP_NAMES ; do
	govc vm.power -on ${CLUSTER_NAME}-$name
done

