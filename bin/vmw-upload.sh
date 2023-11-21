#!/bin/bash -e

common/scripts/validate.sh $@

if [ ! "$CLUSTER_NAME" ]; then
	eval `common/scripts/cluster-config.sh $@ || exit 1`
fi

. ~/.vmware.conf
[ ! "$ISO_DATASTORE" ] && ISO_DATASTORE=$GOVC_DATASTORE

# If the ISO is newer, then upload it
if [ "$(find $MANEFEST_DIR/agent.x86_64.iso -newer $MANEFEST_DIR/agent.x86_64.iso.uploaded)" ]; then
	echo Uploading image $MANEFEST_DIR/agent.x86_64.iso to [$ISO_DATASTORE] images/agent-${CLUSTER_NAME}.iso

	if govc datastore.upload -ds $ISO_DATASTORE $MANEFEST_DIR/agent.x86_64.iso images/agent-${CLUSTER_NAME}.iso; then
		touch $MANEFEST_DIR/agent.x86_64.iso.uploaded 
	else
		echo "Warning: ISO file may be attached to a running VM and cannot be overwritten.  Stop the VM first."
	fi
else
	echo "Image file '$MANEFEST_DIR/agent-${CLUSTER_NAME}.iso' already uploaded to [$ISO_DATASTORE] images/agent-${CLUSTER_NAME}.iso"
fi


