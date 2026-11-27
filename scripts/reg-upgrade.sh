#!/bin/bash
# Dispatcher: upgrades the registry that ABA installed for this mirror.
# Reads persistent state from $regcreds_dir/state.sh to determine vendor
# and whether it was a local or remote install.

[ -z "${INFO_ABA+x}" ] && export INFO_ABA=1

source scripts/include_all.sh

aba_debug "Starting: $0 $* in $PWD"

regcreds_dir=$HOME/.aba/mirror/$(basename "$PWD")

if [ ! -s "$regcreds_dir/state.sh" ]; then
	aba_abort "The registry for this mirror is not installed (no regcreds/state.sh)." \
		"Install one first: $(aba_cmd install)"
fi

source "$regcreds_dir/state.sh"

if [ "${reg_vendor:-}" = "existing" ]; then
	aba_abort \
		"This is an externally-managed registry (registered, not installed by ABA)." \
		"Upgrade it with the tools that installed it."
fi

# A state.sh written before reg_status existed belongs to a finished install.
if [ "${reg_status:-installed}" != "installed" ]; then
	aba_abort "The registry is not installed (reg_status=$reg_status in regcreds/state.sh)." \
		"Finish the install first: $(aba_cmd install)"
fi

# PLANs are emitted by the upgrade Makefile target (scripts/progress-plan.sh upgrade)

case "${reg_vendor:-}" in
	quay)
		# Without the root options, mirror-registry would upgrade its default
		# root, not the data this registry uses.
		if [ -z "${reg_root_opts:-}" ]; then
			aba_abort "regcreds/state.sh has no reg_root_opts. Cannot tell mirror-registry where the registry data is."
		fi
		if [ "$reg_ssh_key" ]; then
			exec scripts/reg-upgrade-quay-remote.sh "$@"
		fi
		exec scripts/reg-upgrade-quay.sh "$@"
		;;
	docker|"$_OMR_VENDOR")
		aba_abort "Upgrade of a $reg_vendor registry is not supported yet. Only Quay can be upgraded."
		;;
	*)
		aba_abort "Unknown registry vendor '${reg_vendor:-}' in regcreds/state.sh"
		;;
esac
