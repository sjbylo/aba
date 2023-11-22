#!/bin/bash -e

[ ! "$1" ] && echo Usage: `basename $0` --dir directory && exit 1
[ "$DEBUG_ABA" ] && set -x

common/scripts/validate.sh $@

#eval `cluster-config.sh $@`
if [ ! "$CLUSTER_NAME" ]; then
	eval `common/scripts/cluster-config.sh $@ || exit 1`
fi

. ~/.vmware.conf || exit 1

i=1
for name in $CP_NAMES $WORKER_NAMES; do
	echo Destroy VM ${CLUSTER_NAME}-$name
	govc vm.destroy ${CLUSTER_NAME}-$name || true
done

[ "$VC" ] && echo govc object.destroy $FOLDER
[ "$VC" ] && govc object.destroy $FOLDER || true

