#!/bin/bash 

source scripts/include_all.sh

[ "$1" ] && set -x

source mirror.conf

echo Uninstalling mirror registry from host $reg_host ...
##./mirror-registry uninstall -v || true

if [ "$reg_ssh" ]; then
	./mirror-registry uninstall -v \
		--targetHostname $reg_host \
  		--targetUsername $(whoami) \
  		-k ~/.ssh/id_rsa 
else
	./mirror-registry uninstall -v 
fi


