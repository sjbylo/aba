#!/bin/bash
# Validate VM state against marker files.
# Called from the Makefile 'check' target (ifdef HV_PREFIX only).
#
# When .vms-ready exists (VMs were supposedly created), verify
# that VMs still exist on the hypervisor.  If they're gone, remove
# stale markers so Make can re-create them.
#
# Exit 0: proceed normally.
# Exit 1: problem detected that blocks the build.

source scripts/include_all.sh

# Nothing to check if VMs were never created
[ -f .vms-ready ] || exit 0

# Determine platform from config files (same detection as the Makefile)
if [ -s vmware.conf ]; then
	_hv=vmw
	ensure_govc
	source <(normalize-vmware-conf)
elif [ -s kvm.conf ]; then
	_hv=kvm
	ensure_virsh
	source <(normalize-kvm-conf)
else
	exit 0
fi

if [ ! "$CLUSTER_NAME" ]; then
	scripts/cluster-config-check.sh || exit 1
	eval "$(scripts/cluster-config.sh)" || exit 1
fi

source scripts/vm-provider.sh
vm_provider_load "$_hv"

_rc=0
vm_exists_any || _rc=$?

case "$_rc" in
	0)
		# VMs exist — proceed normally
		;;
	1)
		# VMs are gone — remove stale markers to allow re-creation
		aba_warn "VMs no longer exist — removing stale markers to allow re-creation"
		rm -f .vms-stopped .iso-uploaded .vms-ready
		;;
	*)
		# Hypervisor unreachable — warn but don't block
		aba_warn "Cannot verify VM state (hypervisor unreachable)"
		;;
esac

exit 0
