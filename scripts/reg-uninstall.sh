#!/bin/bash 

source scripts/include_all.sh

[ "$1" ] && set -x

source <(normalize-aba-conf)
source <(normalize-mirror-conf)

if [ -s reg-uninstall.sh ]; then
	echo Uninstalling mirror registry from host $reg_host ...
	rm -f regcreds/*
	bash -e ./reg-uninstall.sh
	rm -f ./reg-uninstall.sh
	exit 0
else
	echo
	#echo "Warning: No uninstall script 'mirror/reg-uninstall.sh' found."
	echo "Warning: No Quay installation detected."
	echo "If Aba did not install a mirror registry, uninstall it manually." 
	echo
	sleep 5
	#read yn
fi

# Try to uninstall any existing registry

# Has user defined a registry root dir?
if [ "$reg_root" ]; then
	reg_root_opt="--quayRoot $reg_root --quayStorage $reg_root/quay-storage --pgStorage $reg_root/pg-data"
else
	# The default path
	reg_root=$HOME/quay-install
fi

if [ "$reg_ssh" ] && ssh $(whoami)@$reg_host podman ps | grep registry; then
	cmd="./mirror-registry uninstall -v --targetHostname $reg_host --targetUsername $(whoami) --autoApprove -k $reg_ssh $reg_root_opt"
	echo "Running command: $cmd"
	$cmd
        ##./mirror-registry uninstall -v --targetHostname $reg_host --targetUsername $(whoami) --autoApprove -k $reg_ssh $reg_root_opt

elif podman ps | grep registry; then
	cmd="./mirror-registry uninstall -v --autoApprove $reg_root_opt"
	echo "Running command: $cmd"
	$cmd
	##./mirror-registry uninstall -v --autoApprove $reg_root_opt

	rm -f regcreds/*
else
	echo No mirror registry to uninstall
fi

echo

