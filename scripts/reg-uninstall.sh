#!/bin/bash 

source scripts/include_all.sh

[ "$1" ] && set -x

source <(normalize-aba-conf)
source <(normalize-mirror-conf)

if [ -s reg-uninstall.sh ]; then
	source reg-uninstall.sh  # Source the reg_host_to_del var

	if ask "Uninstall the mirror registry from host $reg_host_to_del"; then
		#echo Uninstalling mirror registry from host $reg_host ...
		reg_delete
		rm -f regcreds/*
		rm -f ./reg-uninstall.sh

		exit 0
	fi
	exit 1
else
	echo
	echo "Warning: No Quay installation detected."
	echo "         If you installed a registry and want to remove it, please uninstall it manually." 
	echo
	sleep 5
fi

# Try to uninstall any existing registry

# Has user defined a registry root dir?
if [ "$reg_root" ]; then
	reg_root_opt="--quayRoot $reg_root --quayStorage $reg_root/quay-storage --pgStorage $reg_root/pg-data"
else
	# The default path
	reg_root=$HOME/quay-install
fi

if [ "$reg_ssh" ] && ssh $(whoami)@$reg_host podman ps | grep -q registry; then
	if ask "Uninstall the mirror registry from host $reg_host"; then
		cmd="./mirror-registry uninstall -v --targetHostname $reg_host --targetUsername $(whoami) --autoApprove -k $reg_ssh $reg_root_opt"
		echo "Running command: $cmd"
		$cmd
	else
		exit 1
	fi
elif podman ps | grep -q registry; then
	if ask "Uninstall the mirror registry from localhost"; then
		cmd="./mirror-registry uninstall -v --autoApprove $reg_root_opt"
		echo "Running command: $cmd"
		$cmd

		rm -f regcreds/*
	else
		exit 1
	fi
else
	echo No mirror registry to uninstall
fi

echo

