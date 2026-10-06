#!/bin/bash
# Uninstall the Go-based Quay mirror registry (quay-ng) from localhost.
# Called by reg-uninstall.sh dispatcher; reads state from $regcreds_dir/state.sh.
#
# Idempotent: if probes show the registry is already fully gone, clear local
# state and succeed. Leftover state after cleanup still aborts.

[ -z "${INFO_ABA+x}" ] && export INFO_ABA=1

source scripts/reg-common.sh

aba_debug "Starting: $0 $*"

source <(normalize-aba-conf)
source <(normalize-mirror-conf)
export regcreds_dir=$HOME/.aba/mirror/$(basename "$PWD")
export regcreds_display="regcreds"

if [ ! -s "$regcreds_dir/state.sh" ]; then
	aba_abort "No $_QUAY_NG_VENDOR registry state found in $regcreds_display/state.sh"
fi

source "$regcreds_dir/state.sh"

_QUADLET_DIR="$HOME/.config/containers/systemd"
_QUADLET_FILE="$_QUADLET_DIR/quay.container"
_SERVICE_NAME="quay.service"

if ask -n --auto-yes "Uninstall $_QUAY_NG_VENDOR registry on localhost at $reg_host:$reg_port (data: $reg_root)"; then

	aba_progress "START|uninst_remove"

	_stale=$(reg_stale_report "$_QUAY_NG_VENDOR")
	if [ -z "$_stale" ]; then
		aba_info "$_QUAY_NG_VENDOR registry already gone on localhost -- clearing local state"
		reg_close_firewall
		aba_progress "DONE|uninst_remove"
		aba_progress "START|uninst_cleanup"
		reg_finish_uninstall "$_QUAY_NG_VENDOR" "already uninstalled"
		aba_progress "DONE|uninst_cleanup"
		exit 0
	fi

	if systemctl --user is-active "$_SERVICE_NAME" &>/dev/null; then
		aba_info "Stopping $_SERVICE_NAME ..."
		systemctl --user stop "$_SERVICE_NAME" || true
	else
		aba_info "Service $_SERVICE_NAME not running."
	fi

	if [ -f "$_QUADLET_FILE" ]; then
		aba_info "Removing Quadlet unit file ..."
		rm -f "$_QUADLET_FILE"
		systemctl --user daemon-reload 2>/dev/null || true
	fi

	if reg_ask_delete_data "$reg_root"; then
		reg_rm_data_dir "$_QUAY_NG_VENDOR" "$reg_root"
	fi

	reg_close_firewall

	aba_progress "DONE|uninst_remove"
	aba_progress "START|uninst_cleanup"

	_stale=$(reg_stale_report "$_QUAY_NG_VENDOR")
	if [ -n "$_stale" ]; then
		aba_progress "FAIL|uninst_cleanup"
		aba_abort \
			"$_QUAY_NG_VENDOR registry uninstall left stale state:" \
			"$_stale" \
			"Investigate and clean up manually before retrying."
	fi

	reg_finish_uninstall "$_QUAY_NG_VENDOR" "uninstall successful"
	aba_progress "DONE|uninst_cleanup"
	exit 0
fi

exit 1
