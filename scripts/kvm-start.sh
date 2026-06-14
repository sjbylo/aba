#!/bin/bash
# Start the VMs on the KVM host.
# Thin shim over the VM provider seam -- see scripts/vm-provider.sh.

source scripts/include_all.sh

aba_debug "Running: $0 $*" >&2

. <(process_args $*)
. <(echo $* | tr " " "\n")

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

scope=all
[ "$workers" ] && scope=workers
[ "$masters" ] && scope=masters
# || exit $?: vm_start returns 1 when no VMs exist or user declines.
# The || suppresses the ERR trap; exit $? preserves the error for callers.
vm_start "$scope" || exit $?
