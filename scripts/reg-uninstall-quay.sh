#!/bin/bash
# Uninstall Quay mirror registry from localhost.
# Called by reg-uninstall.sh dispatcher; reads state from $regcreds_dir/state.sh.
#
# Idempotent: if probes show the registry is already fully gone, clear local
# state and succeed without calling mirror-registry uninstall. If uninstall
# fails but probes then show fully gone (e.g. Ansible fails because the
# service unit is already absent), treat as success. Leftover state still aborts.

[ -z "${INFO_ABA+x}" ] && export INFO_ABA=1

source scripts/reg-common.sh

aba_debug "Starting: $0 $*"

reg_pre_uninstall "Quay"

if ask -n --auto-yes "Uninstall Quay mirror registry on localhost, installed at $reg_host:$reg_port (root: $reg_root)"; then

	aba_progress "START|uninst_remove"

	_stale=$(reg_stale_report quay)
	if [ -z "$_stale" ]; then
		aba_info "Quay registry already gone on localhost -- clearing local state"
		reg_close_firewall
		aba_progress "DONE|uninst_remove"
		aba_progress "START|uninst_cleanup"
		reg_finish_uninstall "Quay" "already uninstalled"
		aba_progress "DONE|uninst_cleanup"
		exit 0
	fi

	reg_quay_remove

	reg_close_firewall

	aba_progress "DONE|uninst_remove"
	aba_progress "START|uninst_cleanup"

	reg_finish_uninstall "Quay" "uninstall successful"
	aba_progress "DONE|uninst_cleanup"
	exit 0
fi

exit 1
