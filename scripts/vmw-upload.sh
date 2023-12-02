#!/bin/bash -e

source scripts/include_all.sh

scripts/install-govc.sh

[ "$1" ] && set -x

if [ ! "$CLUSTER_NAME" ]; then
	eval `scripts/cluster-config.sh || exit 1`
fi

source vmware.conf
[ ! "$ISO_DATASTORE" ] && ISO_DATASTORE=$GOVC_DATASTORE

echo Uploading image $MANEFEST_DIR/agent.x86_64.iso to [$ISO_DATASTORE] images/agent-${CLUSTER_NAME}.iso

if govc datastore.upload -ds $ISO_DATASTORE $MANEFEST_DIR/agent.x86_64.iso images/agent-${CLUSTER_NAME}.iso; then
	touch $MANEFEST_DIR/agent.x86_64.iso.uploaded 
else
	echo "Warning: ISO file may be attached to a running VM and cannot be overwritten.  Stop the VM first?"
fi


