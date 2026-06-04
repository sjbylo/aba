#!/bin/bash
# Check if at least one VM exists.
# Thin shim over the VM provider seam -- see scripts/vm-provider.sh.

source scripts/include_all.sh

if [ -s vmware.conf ]; then
	ensure_govc
	source <(normalize-vmware-conf)  # This is needed for $VC_FOLDER
else
	aba_info "vmware.conf file not defined. Run 'aba vmw' to create it if needed"
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
vm_provider_load vmw
# || exit 1 keeps the call in a conditional context so the ERR trap doesn't
# fire on the expected "no VMs exist" return code (which is a normal result,
# not a script error).
vm_exists_any || exit 1
