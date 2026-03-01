#!/bin/bash
# Deregister an externally-managed mirror registry.
# Only removes local credentials (regcreds dir) -- never touches the actual registry.
# Called by reg-uninstall.sh when state.sh contains REG_VENDOR=existing.

[ -z "${INFO_ABA+x}" ] && export INFO_ABA=1

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

source <(normalize-mirror-conf)
export regcreds_dir=$HOME/.aba/mirror/$(basename "$PWD")

if [ ! -d "$regcreds_dir" ]; then
	aba_info "No credentials found in $regcreds_dir -- nothing to deregister."
	exit 0
fi

aba_info "Deregistering existing registry: ${reg_host:-unknown}:${reg_port:-unknown}"

# Back up regcreds before removing (safety net)
rm -rf "${regcreds_dir}.bk"
mv "$regcreds_dir" "${regcreds_dir}.bk"
aba_info "Credentials backed up to ${regcreds_dir}.bk/"

rm -f .installed
touch .uninstalled

echo
aba_info_ok "Existing registry deregistered (registry itself was not modified)."
aba_info "Credentials backed up to: ${regcreds_dir}.bk/"
