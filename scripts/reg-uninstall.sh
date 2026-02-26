#!/bin/bash
# Dispatcher: uninstalls the currently installed registry.
# Reads persistent state from $regcreds_dir/state.sh to determine vendor
# and whether it was a local or remote install.

[ -z "${INFO_ABA+x}" ] && export INFO_ABA=1

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

source <(normalize-aba-conf)
source <(normalize-mirror-conf)

verify-aba-conf || true

# Primary path: use persistent state.sh written at install time
if [ -s "$regcreds_dir/state.sh" ]; then
	source "$regcreds_dir/state.sh"

	if [ "$REG_SSH_KEY" ]; then
		exec scripts/reg-uninstall-remote.sh "$REG_VENDOR" "$@"
	else
		exec scripts/reg-uninstall-${REG_VENDOR}.sh "$@"
	fi
fi

# Backward compat: old-style reg-uninstall.sh from pre-migration installs
if [ -s reg-uninstall.sh ]; then
	source reg-uninstall.sh

	if ask "Uninstall the previously installed mirror registry on host $reg_host_to_del"; then
		reg_delete

		rm -rf "${regcreds_dir:?}/"*
		rm -f ./reg-uninstall.sh
		rm -f .installed
		touch .uninstalled

		exit 0
	fi

	exit 1
fi

# Fallback: no state file found -- try to detect running containers
aba_warning \
	"No registry state found in $regcreds_dir/state.sh." \
	"Attempting to detect a running registry ..."

sleep 1

verify-mirror-conf || exit 1

if [ ! "$data_dir" ]; then data_dir=~; fi
if [ ! "$reg_ssh_user" ]; then reg_ssh_user=$(whoami); fi

ssh_conf_file=~/.aba/ssh.conf

export ASK_OVERRIDE=
export ask=1

if [ "$reg_ssh_key" ] && ssh -F $ssh_conf_file $reg_ssh_user@$reg_host podman ps 2>/dev/null | grep -q registry; then
	reg_root=$data_dir/quay-install
	reg_root_opt="--quayRoot \"$reg_root\" --quayStorage \"$reg_root/quay-storage\" --sqliteStorage \"$reg_root/sqlite-storage\""

	if ask "Registry detected on host $reg_host. Uninstall this mirror registry"; then
		cmd="eval ./mirror-registry uninstall -v --targetHostname $reg_host --targetUsername $reg_ssh_user --autoApprove -k \"$reg_ssh_key\" $reg_root_opt"
		aba_info "Running command: $cmd"
		if [ -d "$regcreds_dir" ]; then rm -rf "${regcreds_dir}.bk" && mv "$regcreds_dir" "${regcreds_dir}.bk"; fi
		$cmd || exit 1
	else
		exit 1
	fi
elif podman ps 2>/dev/null | grep -q registry; then
	reg_root=$data_dir/quay-install
	reg_root_opt="--quayRoot \"$reg_root\" --quayStorage \"$reg_root/quay-storage\" --sqliteStorage \"$reg_root/sqlite-storage\""

	if ask "Mirror registry detected on localhost. Uninstall this mirror registry"; then
		cmd="eval ./mirror-registry uninstall -v --autoApprove $reg_root_opt"
		aba_info "Running command: $cmd"
		if [ -d "$regcreds_dir" ]; then rm -rf "${regcreds_dir}.bk" && mv "$regcreds_dir" "${regcreds_dir}.bk"; fi
		$cmd || exit 1
	else
		exit 1
	fi
else
	aba_info "No mirror registry to uninstall"
	exit 0
fi

rm -rf "${regcreds_dir:?}/"*
rm -f .installed
touch .uninstalled

aba_info_ok "Registry uninstall successful"
