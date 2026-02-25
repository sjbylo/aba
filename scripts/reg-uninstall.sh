#!/bin/bash 

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

#source <(normalize-aba-conf)
source <(normalize-mirror-conf)

#verify-aba-conf  || true

# Primary path: use persistent state.sh written at install time
if [ -s "$regcreds_dir/state.sh" ]; then
	source "$regcreds_dir/state.sh"

	if ask "Uninstall the previously installed mirror registry on host $REG_HOST"; then

		if [ "$REG_SSH_KEY" ]; then
			cmd="./mirror-registry uninstall -v --targetHostname $REG_HOST --targetUsername $REG_SSH_USER --autoApprove -k \"$REG_SSH_KEY\" $REG_ROOT_OPTS"
		else
			cmd="./mirror-registry uninstall -v --autoApprove $REG_ROOT_OPTS"
		fi

		aba_info "Running command: $cmd"
		eval $cmd || exit 1

		rm -rf "${regcreds_dir:?}/"*
		rm -f .installed 
		touch .uninstalled

		aba_info_ok "Registry uninstall successful"
		exit 0
	fi

	exit 1
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
	"No Quay installation state found in $regcreds_dir/state.sh." \
	"Attempting to detect a running registry..."

sleep 1

verify-mirror-conf || exit 1

[ ! "$data_dir" ] && data_dir=\~
reg_root=$data_dir/quay-install

[ ! "$reg_ssh_user" ] && reg_ssh_user=$(whoami)

reg_root_opt="--quayRoot \"$reg_root\" --quayStorage \"$reg_root/quay-storage\" --sqliteStorage \"$reg_root/sqlite-storage\""

export ASK_OVERRIDE=
export ask=1

if [ "$reg_ssh_key" ] && ssh -F ~/.aba/ssh.conf $reg_ssh_user@$reg_host podman ps | grep -q registry; then
	if ask "Registry detected on host $reg_host. Uninstall this mirror registry"; then
		cmd="eval ./mirror-registry uninstall -v --targetHostname $reg_host --targetUsername $reg_ssh_user --autoApprove -k \"$reg_ssh_key\" $reg_root_opt"
		aba_info "Running command: $cmd"
		[ -d "$regcreds_dir" ] && rm -rf "${regcreds_dir}.bk" && mv "$regcreds_dir" "${regcreds_dir}.bk"
		$cmd || exit 1
	else
		exit 1
	fi
elif podman ps | grep -q registry; then
	aba_debug Local mirror registry detected. Value of ask: $ask

	if ask "Mirror registry detected on localhost.  Uninstall this mirror registry"; then
		cmd="eval ./mirror-registry uninstall -v --autoApprove $reg_root_opt"
		aba_info "Running command: $cmd"
		[ -d "$regcreds_dir" ] && rm -rf "${regcreds_dir}.bk" && mv "$regcreds_dir" "${regcreds_dir}.bk"
		$cmd || exit 1
	else
		exit 1
	fi
else
	aba_info "No mirror registry to uninstall" 

	exit 0
fi

aba_info_ok "Registry uninstall successful"
