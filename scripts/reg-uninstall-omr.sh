#!/bin/bash
# Uninstall the Go-based Quay mirror registry (omr) from localhost.
# Called by reg-uninstall.sh dispatcher; reads state from $regcreds_dir/state.sh.
#
# Idempotent: if probes show the registry is already fully gone, clear local
# state and succeed. Leftover state after cleanup still aborts.

[ -z "${INFO_ABA+x}" ] && export INFO_ABA=1

source scripts/reg-common.sh

aba_debug "Starting: $0 $*"

reg_pre_uninstall "$_OMR_VENDOR"

if ask -n --auto-yes "Uninstall $_OMR_VENDOR registry on localhost at $reg_host:$reg_port (data: $reg_root)"; then

	aba_progress "START|uninst_remove"

	# A stopped registry has no running container/port but its Quadlet unit
	# still exists.  mirror-registry uninstall needs a running service to
	# remove cleanly.  Start it first so the uninstall tool can do its job.
	if [ "${reg_running:-}" = "false" ]; then
		aba_info "Registry is stopped — starting it before uninstall ..."
		reg_start_vendor "$_OMR_VENDOR"
	fi

	_stale=$(reg_stale_report "$_OMR_VENDOR")
	if [ -z "$_stale" ]; then
		aba_info "$_OMR_VENDOR registry already gone on localhost -- clearing local state"
		reg_close_firewall
		aba_progress "DONE|uninst_remove"
		aba_progress "START|uninst_cleanup"
		reg_finish_uninstall "$_OMR_VENDOR" "already uninstalled"
		aba_progress "DONE|uninst_cleanup"
		exit 0
	fi

	reg_omr_remove

	reg_close_firewall

	aba_progress "DONE|uninst_remove"
	aba_progress "START|uninst_cleanup"

	reg_finish_uninstall "$_OMR_VENDOR" "uninstall successful"
	aba_progress "DONE|uninst_cleanup"
	exit 0
fi

exit 1
