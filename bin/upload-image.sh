#!/bin/bash -e

common/scripts/validate.sh $@

if [ ! "$CLUSTER_NAME" ]; then
	eval `common/scripts/cluster-config.sh $@ || exit 1`
fi

. ~/.vmware.conf

#if [ ! -f $MANEFEST_DIR/agent.x86_64.iso.uploaded ]; then
	echo Uploading image $MANEFEST_DIR/agent.x86_64.iso to images/agent-${CLUSTER_NAME}.iso
set -x
	govc datastore.upload -ds $ISO_DATASTORE $MANEFEST_DIR/agent.x86_64.iso images/agent-${CLUSTER_NAME}.iso && touch $MANEFEST_DIR/agent.x86_64.iso.uploaded \
		|| echo "Warning: ISO files, attached to running VMs, cannot be overwritten.  Stop the VM first."
#else
#	echo "Image file '$MANEFEST_DIR/agent-${CLUSTER_NAME}.iso' already uploaded to images/agent-${CLUSTER_NAME}.iso"
#fi

