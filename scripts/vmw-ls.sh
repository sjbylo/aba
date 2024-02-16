#!/bin/bash 

source scripts/include_all.sh

[ "$1" ] && set -x

if [ -s vmware.conf ]; then
	source <(normalize-vmware-conf)  # This is needed for $VMW_FOLDER
else
	echo "vmware.conf file not defined. Run 'make vmw' to create it if needed"
	exit 0
fi

if [ ! "$CLUSTER_NAME" ]; then
	scripts/cluster-config-check.sh
	eval `scripts/cluster-config.sh || exit 1`
fi

#source <(normalize-aba-conf)  # Fetch the 'ask' param

govc ls $FOLDER

