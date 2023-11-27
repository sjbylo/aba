#!/bin/bash -e

#[ ! "$1" ] && echo Usage: `basename $0` --dir directory && exit 1
#[ "$DEBUG_ABA" ] && set -x

if [ ! "$CLUSTER_NAME" ]; then
	eval `scripts/cluster-config.sh || exit 1`
fi

#bin/init.sh $@

. ~/.vmware.conf

for name in $CP_NAMES $WORKER_NAMES; do
	govc vm.power -off ${CLUSTER_NAME}-$name || true
done

