#!/bin/bash
# Dispatcher: installs the configured registry vendor (auto/quay/docker).
# Resolves reg_vendor, then exec's the appropriate vendor-specific script.
# For remote installs (reg_ssh_key defined), delegates to reg-install-remote.sh.

[ -z "${INFO_ABA+x}" ] && export INFO_ABA=1

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

source <(normalize-mirror-conf)
export regcreds_dir=$HOME/.aba/mirror/$(basename "$PWD")

# REG_VENDOR_OVERRIDE lets Makefile backward-compat aliases force a specific vendor
vendor="${REG_VENDOR_OVERRIDE:-$(resolved_reg_vendor)}"

aba_debug "Resolved registry vendor: $vendor (reg_vendor=${reg_vendor:-auto})"

# "existing" = externally managed registry; nothing to install
if [ "$vendor" = "existing" ]; then
	aba_debug "Registry vendor is 'existing' -- skipping install (externally managed)"
	exit 0
fi

# Dispatch: remote (SSH) or local
if [ "$reg_ssh_key" ]; then
	exec scripts/reg-install-remote.sh "$vendor" "$@"
else
	exec scripts/reg-install-${vendor}.sh "$@"
fi
