#!/bin/bash
# Upload ISO image to the KVM host

source scripts/include_all.sh

ARCH=$(uname -m)
[ "$ARCH" = "amd64" ] && ARCH=x86_64

aba_debug "Running: $0 $*" >&2

if [ -s kvm.conf ]; then
	ensure_virsh
	source <(normalize-kvm-conf)
else
	aba_info "kvm.conf file not defined. Run 'aba kvm' to create it if needed"
	exit 0
fi

if [ ! "$CLUSTER_NAME" ]; then
	scripts/cluster-config-check.sh
	eval "$(scripts/cluster-config.sh)" || exit 1
fi

iso_src="$ASSETS_DIR/agent.${ARCH}.iso"
iso_dest="${KVM_STORAGE_POOL}/agent-${CLUSTER_NAME}.iso"

aba_info "Uploading image ${iso_src} to ${KVM_HOST}:${iso_dest}"

if ! scp -o StrictHostKeyChecking=no "$iso_src" "${KVM_HOST}:${iso_dest}"; then
	echo_red "ISO file failed to upload to KVM host!"
	exit 1
fi

exit 0
