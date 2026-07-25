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
	eval "$(scripts/cluster-config.sh)" || exit 1
fi

[ ! "$ISO_DATASTORE" ] && ISO_DATASTORE=$GOVC_DATASTORE

[ -s "$ASSETS_DIR/agent.$ARCH.iso" ] || aba_abort "Local ISO not found: $ASSETS_DIR/agent.$ARCH.iso" \
	"Run 'aba iso' first to generate it."

echo Uploading image $ASSETS_DIR/agent.$ARCH.iso to [$ISO_DATASTORE] images/agent-${CLUSTER_NAME}.iso

source scripts/vm-vmw.sh

set +e
trap - ERR
if ! try_cmd -n 3 -d 5 -D 5 -m "ISO upload to [$ISO_DATASTORE]" -- \
	vmp_upload_iso "$ASSETS_DIR/agent.$ARCH.iso" "$ISO_DATASTORE" "images/agent-${CLUSTER_NAME}.iso"
then
	aba_abort "ISO file failed to upload!" \
		"Common causes: the ISO is attached to a running VM (stop it with 'aba stop')," \
		"a stale file on the datastore (delete it via 'govc datastore.rm'), or a transient vCenter/datastore error."
fi

exit 0

