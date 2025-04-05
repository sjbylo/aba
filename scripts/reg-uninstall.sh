#!/bin/bash 

source scripts/include_all.sh

[ "$1" ] && set -x

source <(normalize-aba-conf)
source <(normalize-mirror-conf)

verify-aba-conf  || true # || exit 1  # ocp_version and ocp_channel can be missing
verify-mirror-conf || exit 1

if [ -s reg-uninstall.sh ]; then
	source reg-uninstall.sh  # Source the reg_host_to_del var and reg_delete fn()

	if ask "Uninstall the mirror registry on host $reg_host_to_del"; then
		#echo Uninstalling mirror registry from host $reg_host ...
		reg_delete
		#[ "$reg_root" ] && eval ls -la $reg_root || ls -la ~/quay-install
		#[ "$reg_root" ] && eval rm -rf $reg_root || rm -rf ~/quay-install
		rm -rf regcreds/*
		rm -f ./reg-uninstall.sh
		rm -f .installed 
		touch .uninstalled

		exit 0
	fi
	exit 1
else
	echo
	echo "Warning: No Quay installation detected that 'aba' installed."
	echo "         If you installed a registry and want to remove it, please uninstall it manually." 
	echo
	sleep 2
fi

[ ! "$reg_ssh_user" ] && reg_ssh_user=$(whoami)

# Try to uninstall any existing registry

# Has user defined a registry root dir?
if [ "$reg_root" ]; then
	reg_root_opt="--quayRoot \"$reg_root\" --quayStorage \"$reg_root/quay-storage\" --sqliteStorage \"$reg_root/sqlite-storage\""
else
	# The default path
	## FIX # reg_root=/home/$reg_ssh_user/quay-install   # Not used in thie script!
	reg_root="~/quay-install"   # Used in $reg_root_opt above
	## FIX # [ "$reg_ssh_user" = "root" ] && reg_root=/root/quay-install
fi

if [ "$reg_ssh_key" ] && ssh $reg_ssh_user@$reg_host podman ps | grep -q registry; then
	if ask "Registry detected on host $reg_host. Uninstall this mirror registry"; then
		cmd="eval ./mirror-registry uninstall -v --targetHostname $reg_host --targetUsername $reg_ssh_user --autoApprove -k \"$reg_ssh_key\" $reg_root_opt"
		echo "Running command: $cmd"
		$cmd || exit 1

		#[ "$reg_root" ] && ssh $reg_ssh_user@$reg_host rm -rf $reg_root || ssh $reg_ssh_user@$reg_host rm -rf ~/quay-install
	else
		exit 1
	fi
elif podman ps | grep -q registry; then
	if ask "Registry detected on localhost.  Uninstall this mirror registry"; then
		cmd="eval ./mirror-registry uninstall -v --autoApprove $reg_root_opt"
		echo "Running command: $cmd"
		$cmd || exit 1
		#[ "$reg_root" ] && eval rm -rf $reg_root || rm -rf ~/quay-install
	else
		exit 1
	fi
else
	echo_red "No mirror registry to uninstall" >&2

	exit 0
fi

echo
echo_green "Registry uninstall successful"

