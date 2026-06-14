#!/bin/bash
# Determine if at least one VM is running on the KVM host.
# Thin shim over the VM provider seam -- see scripts/vm-provider.sh.

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

source scripts/vm-provider.sh
vm_provider_load kvm
vm_on_any
