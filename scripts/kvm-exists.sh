#!/bin/bash
# Check if at least one VM exists on the KVM host.
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
	if [ ! -s install-config.yaml ] || [ ! -s agent-config.yaml ]; then
		exit 1
	fi
	scripts/cluster-config-check.sh
	eval "$(scripts/cluster-config.sh)" || exit 1
fi

source scripts/vm-provider.sh
vm_provider_load kvm
# vm_exists_any returns: 0 = found, 1 = none exist, 2 = hypervisor unreachable.
# Capture via || so the ERR trap does not treat "no VMs" as a script error.
_rc=0
vm_exists_any || _rc=$?
exit $_rc
