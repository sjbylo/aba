#!/bin/bash 

source scripts/include_all.sh

[ "$1" ] && set -x

source mirror.conf

echo Uninstalling mirror registry from host $reg_host ...

if [ "$reg_root" ]; then
	reg_root_opt="--quayRoot $reg_root --quayStorage ${reg_root}-storage"
fi

rm -rf deps/*

if [ -s reg-uninstall.sh ]; then
	bash -e ./reg-uninstall.sh
	rm -f ./reg-uninstall.sh
	exit 0
fi

if [ "$reg_ssh" ]; then

	echo "Running command: ./mirror-registry uninstall -v --targetHostname $reg_host --targetUsername $(whoami) -k ~/.ssh/id_rsa $reg_root_opt"
	./mirror-registry uninstall -v \
		--targetHostname $reg_host \
  		--targetUsername $(whoami) \
		--autoApprove \
  		-k ~/.ssh/id_rsa $reg_root_opt
else
	echo "Running command: ./mirror-registry uninstall -v $reg_root_opt"
	./mirror-registry uninstall -v --autoApprove $reg_root_opt
fi

