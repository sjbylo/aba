#!/bin/bash -e

. scripts/include_all.sh

scripts/install-govc.sh

[ "$1" ] && set -x

if [ ! "$CLUSTER_NAME" ]; then
	eval `scripts/cluster-config.sh || exit 1`
fi

source vmware.conf

for name in $CP_NAMES $WORKER_NAMES; do
	govc vm.power -off ${CLUSTER_NAME}-$name || true
done

