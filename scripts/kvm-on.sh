#!/bin/bash
# Determine if at least one VM is running on the KVM host

source scripts/include_all.sh

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

for name in $CP_NAMES $WORKER_NAMES; do
	state=$(virsh -c "$LIBVIRT_URI" domstate "$(vm_name "$CLUSTER_NAME" "$name")" 2>/dev/null)
	[ "$state" = "running" ] && exit 0
done

exit 1
