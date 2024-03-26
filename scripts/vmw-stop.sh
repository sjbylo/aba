#!/bin/bash 

source scripts/include_all.sh

scripts/install-govc.sh

[ "$1" ] && set -x

if [ -s vmware.conf ]; then
	source <(normalize-vmware-conf)  # This is needed for $VC_FOLDER
else
	echo "vmware.conf file not defined. Run 'make vmw' to create it if needed"
	exit 0
fi

if [ ! "$CLUSTER_NAME" ]; then
	scripts/cluster-config-check.sh
	eval `scripts/cluster-config.sh || exit 1`
fi

for name in $WORKER_NAMES $CP_NAMES; do
	# Shut down guest if vmware tools exist
	govc vm.power -s ${CLUSTER_NAME}-$name  
	
done

