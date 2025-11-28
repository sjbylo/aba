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

echo Uploading image $ASSETS_DIR/agent.$ARCH.iso to [$ISO_DATASTORE] images/agent-${CLUSTER_NAME}.iso

#if ! govc datastore.upload -ds $ISO_DATASTORE $ASSETS_DIR/agent.$ARCH.iso images/agent-${CLUSTER_NAME}.iso | tee /dev/stderr | grep -qi "Uploading.*OK"; then
ret=0
if [ "$PLAIN_OUTPUT" ]; then
	cmd="cat $ASSETS_DIR/agent.$ARCH.iso | govc datastore.upload -ds $ISO_DATASTORE - images/agent-${CLUSTER_NAME}.iso"
	trap - ERR
	set +e
	eval $cmd 
	ret=$?
else
	#FIXME: Is log_file needed if govc returns sensible value
	#mkdir -p $HOME/.aba/tmp
	#log_file=$HOME/.aba/tmp/.upload.$$.log
	#touch $log_file
	cmd="govc datastore.upload -ds $ISO_DATASTORE $ASSETS_DIR/agent.$ARCH.iso images/agent-${CLUSTER_NAME}.iso"
	set +e
	trap - ERR
	eval $cmd #| tee $log_file #|| true
	ret=$?
	#! grep -qi "Uploading.*OK" $log_file && ret=1
fi
if [ $ret -ne 0 ]; then
	# Since govc does not return non-zero on error we need to parse the output for non-success!  #FIXME: true?
	#rm -f $log_file
	echo_red "ISO file failed to upload!"
	echo_red "The ISO may be attached to a running VM and cannot be overwritten.  Stop the VM first with 'aba stop' and try again."
	exit 1
fi

#rm -f $log_file

exit 0

