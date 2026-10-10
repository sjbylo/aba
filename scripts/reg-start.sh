#!/bin/bash
# Start a previously stopped registry.
# Reads persistent state from $regcreds_dir/state.sh to determine vendor
# and whether it was a local or remote install.

[ -z "${INFO_ABA+x}" ] && export INFO_ABA=1

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

source <(normalize-aba-conf)
source <(normalize-mirror-conf)
export regcreds_dir=$HOME/.aba/mirror/$(basename "$PWD")

source scripts/reg-common.sh

if [ ! -s "$regcreds_dir/state.sh" ]; then
	aba_abort "No registry state found in $regcreds_dir/state.sh — is a registry installed?"
fi

source "$regcreds_dir/state.sh"

if [ "$reg_vendor" = "existing" ]; then
	aba_abort \
		"This is an externally-managed registry (registered, not installed by ABA)." \
		"ABA cannot stop/start registries it does not manage."
fi

ssh_conf_file=~/.aba/ssh.conf

aba_progress "START|start_reg"

if [ "$reg_ssh_key" ]; then
	_ssh="ssh -i $reg_ssh_key -F $ssh_conf_file $reg_ssh_user@$reg_host"
	reg_start_vendor "$reg_vendor" "$_ssh"
else
	reg_start_vendor "$reg_vendor"
fi

aba_progress "DONE|start_reg"
aba_progress "START|start_verify"
aba_progress "DONE|start_verify"
