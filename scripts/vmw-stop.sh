#!/bin/bash
# Stop the VMs gracefully with vmware system shutdown.
# Thin shim over the VM provider seam -- see scripts/vm-provider.sh.

source scripts/include_all.sh

aba_debug "Starting: $0 $* in $PWD"

. <(process_args "$@")
. <(echo $* | tr " " "\n")

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

scope=all
[ "$workers" ] && scope=workers
[ "$masters" ] && scope=masters
# 2: the user declined the prompt. That is not a power failure.
# Any other non-zero (a VM that did not accept the shutdown) must stay non-zero.
_rc=0
vm_stop "$scope" || _rc=$?
[ "$_rc" -eq 2 ] && exit 0
exit "$_rc"
