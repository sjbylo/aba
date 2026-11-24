#!/bin/bash
# Power off the VMs immediately.
# Thin shim over the VM provider seam -- see scripts/vm-provider.sh.

source scripts/include_all.sh
aba_debug "Starting: $0 $* in $PWD"

aba_progress "START|ci_vms" || true

if [ -s vmware.conf ]; then
	ensure_govc
	source <(normalize-vmware-conf)  # This is needed for $VC_FOLDER
else
	aba_info "vmware.conf file not defined. Run 'aba vmw' to create it if needed"
	exit 0
fi

if [ ! "$CLUSTER_NAME" ]; then
	scripts/cluster-config-check.sh || exit 1
	eval "$(scripts/cluster-config.sh)" || exit 1
fi

source <(normalize-aba-conf)  # Fetch the 'ask' param
verify-aba-conf || aba_abort "$_ABA_CONF_ERR"

source scripts/vm-provider.sh
vm_provider_load vmw
# 2: the user declined the prompt. That is not a power failure.
_rc=0
vm_kill || _rc=$?
[ "$_rc" -eq 2 ] && exit 0
exit "$_rc"
