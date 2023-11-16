#!/bin/bash -e

common/scripts/validate.sh $@

if [ ! "$CLUSTER_NAME" ]; then
	eval `common/scripts/cluster-config.sh $@ || exit 1`
fi

delete-vms.sh $@

create-vms.sh $@

start-vms.sh $@

