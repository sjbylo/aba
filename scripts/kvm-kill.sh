#!/bin/bash
# Power off the VMs immediately on the KVM host.
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

source <(normalize-aba-conf)
verify-aba-conf || aba_abort "$_ABA_CONF_ERR"

source scripts/vm-provider.sh
vm_provider_load kvm
# || exit 0: vm_kill returns 1 only when user declines the ask prompt.
# The || suppresses the ERR trap (which would print a spurious "Script error").
vm_kill || exit 0
