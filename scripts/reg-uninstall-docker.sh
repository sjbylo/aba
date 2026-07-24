#!/bin/bash
# Uninstall Docker/OCI registry from localhost.
# Called by reg-uninstall.sh dispatcher; reads state from $regcreds_dir/state.sh.
#
# Idempotent: if probes show the registry is already fully gone, clear local
# state and succeed. Leftover state after cleanup still aborts.

[ -z "${INFO_ABA+x}" ] && export INFO_ABA=1

source scripts/include_all.sh
source scripts/reg-common.sh

aba_debug "Starting: $0 $*"

source <(normalize-aba-conf)
source <(normalize-mirror-conf)
export regcreds_dir=$HOME/.aba/mirror/$(basename "$PWD")
export regcreds_display="regcreds"

# No verify-aba-conf — uninstall uses state.sh, not aba.conf values

if [ ! -s "$regcreds_dir/state.sh" ]; then
	aba_abort "No Docker registry state found in $regcreds_display/state.sh"
fi

source "$regcreds_dir/state.sh"

REGISTRY_NAME="registry"

if ask -n --auto-yes "Uninstall Docker registry on localhost at $reg_host:$reg_port (data: $reg_root)"; then

	_stale=$(reg_stale_report docker)
	if [ -z "$_stale" ]; then
		aba_info "Docker registry already gone on localhost -- clearing local state"
		reg_close_firewall
		reg_finish_uninstall "Docker" "already uninstalled"
		exit 0
	fi

	if podman ps -a --format '{{.Names}}' | grep -q "^${REGISTRY_NAME}$"; then
		aba_info "Stopping and removing registry container ..."
		podman rm -f "$REGISTRY_NAME" || true
	else
		aba_info "Registry container '$REGISTRY_NAME' not found (already stopped)."
	fi

	if [ -d "$reg_root" ]; then
		aba_info "Removing registry data at $reg_root ..."
		$SUDO rm -rf "$reg_root"
	fi

	reg_close_firewall

	_stale=$(reg_stale_report docker)
	if [ -n "$_stale" ]; then
		aba_abort \
			"Docker registry uninstall left stale state:" \
			"$_stale" \
			"Investigate and clean up manually before retrying."
	fi

	reg_finish_uninstall "Docker" "uninstall successful"
	exit 0
fi

exit 1
