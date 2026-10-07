#!/bin/bash
# Uninstall Quay mirror registry from a remote host via SSH.
# Called by reg-uninstall.sh dispatcher; reads state from $regcreds_dir/state.sh.
#
# Idempotent: if probes show the registry is already fully gone on the remote
# host, clear local state and succeed. If mirror-registry uninstall fails but
# probes then show fully gone, treat as success. Leftover state still aborts.

[ -z "${INFO_ABA+x}" ] && export INFO_ABA=1

source scripts/reg-common.sh

aba_debug "Starting: $0 $*"

reg_remote_pre_uninstall "Quay"

if ask -n --auto-yes "Uninstall Quay registry on remote host $reg_ssh_user@$reg_host:$reg_root"; then

	aba_progress "START|uninst_remove"

	_stale=$(reg_stale_report quay "$_ssh")
	if [ -z "$_stale" ]; then
		aba_info "Quay registry already gone on $reg_host -- clearing local state"
		reg_close_firewall --ssh
		aba_progress "DONE|uninst_remove"
		aba_progress "START|uninst_cleanup"
		reg_finish_uninstall "Remote Quay" "already uninstalled"
		aba_progress "DONE|uninst_cleanup"
		exit 0
	fi

	reg_quay_remove "$_ssh"

	reg_close_firewall --ssh

	aba_progress "DONE|uninst_remove"
	aba_progress "START|uninst_cleanup"

	reg_finish_uninstall "Remote Quay" "uninstall successful"
	aba_progress "DONE|uninst_cleanup"
	exit 0
fi

exit 1
