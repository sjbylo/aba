#!/bin/bash
# Uninstall the Go-based Quay mirror registry (quay-ng) from a remote host via SSH.
# Called by reg-uninstall.sh dispatcher; reads state from $regcreds_dir/state.sh.
#
# Idempotent: if probes show the registry is already fully gone on the remote
# host, clear local state and succeed. Leftover state after cleanup still aborts.

[ -z "${INFO_ABA+x}" ] && export INFO_ABA=1

source scripts/reg-common.sh

aba_debug "Starting: $0 $*"

reg_remote_pre_uninstall "$_QUAY_NG_VENDOR"

if ask -n --auto-yes "Uninstall $_QUAY_NG_VENDOR registry on remote host $reg_ssh_user@$reg_host:$reg_root"; then

	aba_progress "START|uninst_remove"

	if [ "${reg_running:-}" = "false" ]; then
		aba_info "Registry is stopped — starting it before uninstall ..."
		reg_start_vendor "$_QUAY_NG_VENDOR" "$_ssh"
	fi

	_stale=$(reg_stale_report "$_QUAY_NG_VENDOR" "$_ssh")
	if [ -z "$_stale" ]; then
		aba_info "$_QUAY_NG_VENDOR registry already gone on $reg_host -- clearing local state"
		reg_close_firewall --ssh
		aba_progress "DONE|uninst_remove"
		aba_progress "START|uninst_cleanup"
		reg_finish_uninstall "Remote $_QUAY_NG_VENDOR" "already uninstalled"
		aba_progress "DONE|uninst_cleanup"
		exit 0
	fi

	reg_quay_ng_remove "$_ssh"

	reg_close_firewall --ssh

	aba_progress "DONE|uninst_remove"
	aba_progress "START|uninst_cleanup"

	reg_finish_uninstall "Remote $_QUAY_NG_VENDOR" "uninstall successful"
	aba_progress "DONE|uninst_cleanup"
	exit 0
fi

exit 1
