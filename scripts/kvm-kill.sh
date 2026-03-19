#!/bin/bash
# Power off the VMs immediately on the KVM host

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

source <(normalize-aba-conf)

verify-aba-conf || aba_abort "$_ABA_CONF_ERR"

if [ "$ask" ]; then
	echo
	for name in $CP_NAMES $WORKER_NAMES; do
		echo "${CLUSTER_NAME}-${name}"
	done

	ask "Immediately power down the above virtual machine(s)" || exit 1
fi

for name in $CP_NAMES $WORKER_NAMES; do
	virsh -c "$LIBVIRT_URI" destroy "${CLUSTER_NAME}-${name}" 2>/dev/null || true
done

exit 0
