#!/bin/bash 
# Upload iso image 

source scripts/include_all.sh

ARCH=$(uname -m)
[ "$ARCH" = "amd64" ] && ARCH=x86_64

aba_debug "Running: $0 $*" >&2



if [ -s vmware.conf ]; then
	source <(normalize-vmware-conf)  # This is needed for $VC_FOLDER
else
	aba_info "vmware.conf file not defined. Run 'aba vmw' to create it if needed"
	exit 0
fi

if [ ! "$CLUSTER_NAME" ]; then
	scripts/cluster-config-check.sh
	eval `scripts/cluster-config.sh || exit 1`
fi

[ ! "$ISO_DATASTORE" ] && ISO_DATASTORE=$GOVC_DATASTORE

[ -s "$ASSETS_DIR/agent.$ARCH.iso" ] || aba_abort "Local ISO not found: $ASSETS_DIR/agent.$ARCH.iso" \
	"Run 'aba iso' first to generate it."

echo Uploading image $ASSETS_DIR/agent.$ARCH.iso to [$ISO_DATASTORE] images/agent-${CLUSTER_NAME}.iso

#if ! govc datastore.upload -ds $ISO_DATASTORE $ASSETS_DIR/agent.$ARCH.iso images/agent-${CLUSTER_NAME}.iso | tee /dev/stderr | grep -qi "Uploading.*OK"; then
ret=0
if [ "$PLAIN_OUTPUT" ]; then
	cmd="cat $ASSETS_DIR/agent.$ARCH.iso | govc datastore.upload -ds $ISO_DATASTORE - images/agent-${CLUSTER_NAME}.iso"
	aba_debug "Running: $cmd"
	trap - ERR
	set +e
	eval $cmd 
	ret=$?
else
	cmd="govc datastore.upload -ds $ISO_DATASTORE $ASSETS_DIR/agent.$ARCH.iso images/agent-${CLUSTER_NAME}.iso"
	aba_debug "Running: $cmd"
	set +e
	trap - ERR
	eval $cmd
	ret=$?
	#! grep -qi "Uploading.*OK" $log_file && ret=1
fi
if [ $ret -ne 0 ]; then
	aba_abort "ISO file failed to upload!" \
		"The ISO may be attached to a running VM and cannot be overwritten." \
		"Stop the VM first with 'aba stop' and try again."
fi

# Post-upload verification: ensure the ISO on the datastore is not 0 bytes
remote_size=$(govc datastore.ls -ds $ISO_DATASTORE -l images/agent-${CLUSTER_NAME}.iso 2>/dev/null | awk '{print $1}')
if [ "$remote_size" = "0B" ] || [ -z "$remote_size" ]; then
	aba_abort "Upload verification failed: ISO on datastore is 0 bytes or missing!" \
		"Check datastore connectivity and disk space."
fi

exit 0

