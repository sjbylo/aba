#!/bin/bash
# Uninstall Docker/OCI registry from localhost.
# Called by reg-uninstall.sh dispatcher; reads state from $regcreds_dir/state.sh.

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

	# Post-uninstall assertions: verify Docker registry is fully gone.
	_stale=""
	[ -d "$reg_root" ] && _stale+="  reg_root ($reg_root) still exists"$'\n'
	ss -tlnp | grep -q ":${reg_port:-8443} " && _stale+="  Port ${reg_port:-8443} still listening"$'\n'
	podman ps -a --format '{{.Names}}' | grep -q "^${REGISTRY_NAME}$" && _stale+="  registry container still present"$'\n'
	if [ -n "$_stale" ]; then
		aba_abort \
			"Docker registry uninstall left stale state:" \
			"$_stale" \
			"Investigate and clean up manually before retrying."
	fi

	rm -rf "${regcreds_dir:?}/"*

	aba_success "Docker registry uninstall successful"
	exit 0
fi

exit 1
