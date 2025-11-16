#!/bin/bash 

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

[ "$1" ] && set -x

source <(normalize-aba-conf)
source <(normalize-mirror-conf)

verify-aba-conf  || true # || exit 1  # ocp_version and ocp_channel can be missing
verify-mirror-conf || exit 1

[ ! "$data_dir" ] && data_dir=\~
reg_root=$data_dir/quay-install

if [ -s reg-uninstall.sh ]; then
	source reg-uninstall.sh  # Source the reg_host_to_del var and reg_delete fn()

	if ask "Uninstall the previously installed mirror registry on host $reg_host_to_del"; then

		reg_delete

		rm -rf regcreds/*
		rm -f ./reg-uninstall.sh
		rm -f .installed 
		touch .uninstalled

		exit 0
	fi

	exit 1
else
	aba_warning \
		"No Quay installation detected that 'aba' installed." \
		"If you installed a registry and want to remove it, please uninstall it manually." 

	sleep 1
fi

[ ! "$reg_ssh_user" ] && reg_ssh_user=$(whoami)

# Try to uninstall any existing registry

reg_root_opt="--quayRoot \"$reg_root\" --quayStorage \"$reg_root/quay-storage\" --sqliteStorage \"$reg_root/sqlite-storage\""

if [ "$reg_ssh_key" ] && ssh $reg_ssh_user@$reg_host podman ps | grep -q registry; then
	if ask "Registry detected on host $reg_host. Uninstall this mirror registry"; then
		cmd="eval ./mirror-registry uninstall -v --targetHostname $reg_host --targetUsername $reg_ssh_user --autoApprove -k \"$reg_ssh_key\" $reg_root_opt"
		aba_echo "Running command: $cmd"
		$cmd || exit 1

		#[ "$reg_root" ] && ssh $reg_ssh_user@$reg_host rm -rf $reg_root || ssh $reg_ssh_user@$reg_host rm -rf ~/quay-install
	else
		exit 1
	fi
elif podman ps | grep -q registry; then
	if ask "Registry detected on localhost.  Uninstall this mirror registry"; then
		cmd="eval ./mirror-registry uninstall -v --autoApprove $reg_root_opt"
		aba_echo "Running command: $cmd"
		$cmd || exit 1
		#[ "$reg_root" ] && eval rm -rf $reg_root || rm -rf ~/quay-install
	else
		exit 1
	fi
else
	aba_warning "No mirror registry to uninstall" 

	exit 0
fi

aba_echo_ok "Registry uninstall successful"

