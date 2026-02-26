#!/bin/bash
# Uninstall Docker/OCI registry from localhost.
# Called by reg-uninstall.sh dispatcher; reads state from $regcreds_dir/state.sh.

[ -z "${INFO_ABA+x}" ] && export INFO_ABA=1

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

source <(normalize-aba-conf)
source <(normalize-mirror-conf)
export regcreds_dir=$HOME/.aba/mirror/$(basename "$PWD")

verify-aba-conf || true

if [ ! -s "$regcreds_dir/state.sh" ]; then
	aba_abort "No Docker registry state found in $regcreds_dir/state.sh"
fi

source "$regcreds_dir/state.sh"

REGISTRY_NAME="registry"

if ask "Uninstall Docker registry on localhost at $REG_HOST:$REG_PORT (data: $REG_ROOT)"; then

	if podman ps -a --format '{{.Names}}' | grep -q "^${REGISTRY_NAME}$"; then
		aba_info "Stopping and removing registry container ..."
		podman rm -f "$REGISTRY_NAME" || true
	else
		aba_info "Registry container '$REGISTRY_NAME' not found (already stopped)."
	fi

	if [ -d "$REG_ROOT" ]; then
		aba_info "Removing registry data at $REG_ROOT ..."
		$SUDO rm -rf "$REG_ROOT"
	fi

	rm -rf "${regcreds_dir:?}/"*
	rm -f .installed
	touch .uninstalled

	aba_info_ok "Docker registry uninstall successful"
	exit 0
fi

exit 1
