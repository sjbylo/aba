#!/bin/bash
# Uninstall Quay mirror registry from localhost.
# Called by reg-uninstall.sh dispatcher; reads state from $regcreds_dir/state.sh.

[ -z "${INFO_ABA+x}" ] && export INFO_ABA=1

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

source <(normalize-aba-conf)
source <(normalize-mirror-conf)
export regcreds_dir=$HOME/.aba/mirror/$(basename "$PWD")

# No verify-aba-conf — uninstall uses state.sh, not aba.conf values

if [ ! -s "$regcreds_dir/state.sh" ]; then
	aba_abort "No Quay registry state found in $regcreds_dir/state.sh"
fi

source "$regcreds_dir/state.sh"

if ask "Uninstall Quay mirror registry on localhost, installed at $REG_HOST:$REG_PORT (root: $REG_ROOT)"; then

	ensure_quay_registry

	cmd="./mirror-registry uninstall -v --autoApprove $REG_ROOT_OPTS"

	aba_info "Running command: $cmd"
	eval $cmd || exit 1

	rm -rf "${regcreds_dir:?}/"*
	rm -f .installed
	touch .uninstalled

	aba_info_ok "Quay registry uninstall successful"
	exit 0
fi

exit 1
