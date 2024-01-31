#!/bin/bash 

source scripts/include_all.sh

[ "$1" ] && set -x

source mirror.conf

# FIXME, only the uninstall script needed?
#if [ "$reg_root" ]; then
#	reg_root_opt="--quayRoot $reg_root --quayStorage ${reg_root}-storage"
#fi

if [ -s reg-uninstall.sh ]; then
	echo Uninstalling mirror registry from host $reg_host ...
	rm -f regcreds/*
	bash -e ./reg-uninstall.sh
	rm -f ./reg-uninstall.sh
	exit 0
else
	echo "Warning: No uninstall script 'mirror/reg-uninstall.sh' found."
	echo "If Aba did not install the mirror registry, then uninstall manually. Return to continue, Ctrl-C to abort." 
	read yn
fi

# FIXME: Is this still needed? 
# FIXME, only the uninstall script needed?
#if [ "$reg_ssh" ]; then

#	echo "Running command: ./mirror-registry uninstall -v --targetHostname $reg_host --targetUsername $(whoami) -k $reg_ssh $reg_root_opt"
#	./mirror-registry uninstall -v \
#		--targetHostname $reg_host \
#  		--targetUsername $(whoami) \
#		--autoApprove \
#  		-k $reg_ssh $reg_root_opt
#else
#	echo "Running command: ./mirror-registry uninstall -v $reg_root_opt"
#	./mirror-registry uninstall -v --autoApprove $reg_root_opt
#fi

# If there is no uninstall script, assume nothing to uninstall
#echo No mirror registry to uninstall
echo
