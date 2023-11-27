#!/bin/bash -e

#[ ! "$1" ] && echo Usage: `basename $0` --dir directory && exit 1
#[ "$DEBUG_ABA" ] && set -x

if [ ! "$CLUSTER_NAME" ]; then
	eval `scripts/cluster-config.sh || exit 1`
fi

#bin/init.sh $@

. ~/.vmware.conf
[ ! "$ISO_DATASTORE" ] && ISO_DATASTORE=$GOVC_DATASTORE

# If the ISO is newer, then upload it
###if [ "$(find $MANEFEST_DIR/agent.x86_64.iso -newer $MANEFEST_DIR/agent.x86_64.iso.uploaded)" ]; then
##if [ $MANEFEST_DIR/agent.x86_64.iso -nt $MANEFEST_DIR/agent.x86_64.iso.uploaded ]; then
	echo Uploading image $MANEFEST_DIR/agent.x86_64.iso to [$ISO_DATASTORE] images/agent-${CLUSTER_NAME}.iso

	if govc datastore.upload -ds $ISO_DATASTORE $MANEFEST_DIR/agent.x86_64.iso images/agent-${CLUSTER_NAME}.iso; then
		touch $MANEFEST_DIR/agent.x86_64.iso.uploaded 
	else
		echo "Warning: ISO file may be attached to a running VM and cannot be overwritten.  Stop the VM first?"
	fi
##else
	##echo "Image file '$MANEFEST_DIR/agent-${CLUSTER_NAME}.iso' already uploaded to [$ISO_DATASTORE] images/agent-${CLUSTER_NAME}.iso"
##fi


