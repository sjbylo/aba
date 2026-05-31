#!/bin/bash
# Determine if at least one VM is powered on.
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
	scripts/cluster-config-check.sh
	eval "$(scripts/cluster-config.sh)" || exit 1
fi

source scripts/vm-provider.sh
vm_provider_load vmw
vm_on_any
