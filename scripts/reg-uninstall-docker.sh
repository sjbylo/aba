#!/bin/bash
# Uninstall Docker/OCI registry from localhost.
# Called by reg-uninstall.sh dispatcher; reads state from $regcreds_dir/state.sh.
#
# Idempotent: if probes show the registry is already fully gone, clear local
# state and succeed. Leftover state after cleanup still aborts.

[ -z "${INFO_ABA+x}" ] && export INFO_ABA=1

source scripts/reg-common.sh

aba_debug "Starting: $0 $*"

reg_pre_uninstall "Docker"

if ask -n --auto-yes "Uninstall Docker registry on localhost at $reg_host:$reg_port (data: $reg_root)"; then

	aba_progress "START|uninst_remove"

	_stale=$(reg_stale_report docker)
	if [ -z "$_stale" ]; then
		aba_info "Docker registry already gone on localhost -- clearing local state"
		reg_close_firewall
		aba_progress "DONE|uninst_remove"
		aba_progress "START|uninst_cleanup"
		reg_finish_uninstall "Docker" "already uninstalled"
		aba_progress "DONE|uninst_cleanup"
		exit 0
	fi

	reg_docker_remove

	reg_close_firewall

	aba_progress "DONE|uninst_remove"
	aba_progress "START|uninst_cleanup"

	reg_finish_uninstall "Docker" "uninstall successful"
	aba_progress "DONE|uninst_cleanup"
	exit 0
fi

exit 1
