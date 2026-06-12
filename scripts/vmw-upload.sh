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

source scripts/vm-vmw.sh

set +e
trap - ERR
vmp_upload_iso "$ASSETS_DIR/agent.$ARCH.iso" "$ISO_DATASTORE" "images/agent-${CLUSTER_NAME}.iso"
ret=$?
if [ $ret -ne 0 ]; then
	aba_abort "ISO file failed to upload!" \
		"The ISO may be attached to a running VM and cannot be overwritten." \
		"Stop the VM first with 'aba stop' and try again."
fi

exit 0

