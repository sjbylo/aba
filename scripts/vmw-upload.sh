#!/bin/bash 
# Upload iso image 

source scripts/include_all.sh

scripts/install-govc.sh

[ "$1" ] && set -x

if [ -s vmware.conf ]; then
	source <(normalize-vmware-conf)  # This is needed for $VC_FOLDER
else
	echo "vmware.conf file not defined. Run 'make vmw' to create it if needed"
	exit 0
fi

if [ ! "$CLUSTER_NAME" ]; then
	scripts/cluster-config-check.sh
	eval `scripts/cluster-config.sh || exit 1`
fi

[ ! "$ISO_DATASTORE" ] && ISO_DATASTORE=$GOVC_DATASTORE

echo Uploading image $MANEFEST_DIR/agent.x86_64.iso to [$ISO_DATASTORE] images/agent-${CLUSTER_NAME}.iso

if ! govc datastore.upload -ds $ISO_DATASTORE $MANEFEST_DIR/agent.x86_64.iso images/agent-${CLUSTER_NAME}.iso | tee /dev/tty| grep -qi "Uploading.*OK"; then
	# Since govc does not return non-zero on error we need to parse the output for non-success! 
	output_error "Warning: ISO file may be attached to a running VM and cannot be overwritten.  Try to stop the VM first with 'make stop' and try again."

	exit 1
fi

echo

