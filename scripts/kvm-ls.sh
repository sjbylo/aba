#!/bin/bash
# Display the VMs and their state on the KVM host.
# Thin shim over the VM provider seam -- see scripts/vm-provider.sh.

source scripts/include_all.sh

aba_debug "Starting: $0 $* in $PWD"

if [ -s kvm.conf ]; then
	ensure_virsh
	source <(normalize-kvm-conf)
else
	aba_info "kvm.conf file not defined. Run 'aba kvm' to create it if needed"
	exit 0
fi

if [ ! "$CLUSTER_NAME" ]; then
	vm_load_names || exit 1
fi

source scripts/vm-provider.sh
vm_provider_load kvm
vm_ls
