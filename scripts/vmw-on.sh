#!/bin/bash 
# Determine if at least one VM is powered on

source scripts/include_all.sh

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

# Exit 0 if at least one VM is powered on
for name in $CP_NAMES $WORKER_NAMES; do
	power_state=$(govc vm.info -json ${CLUSTER_NAME}-$name | jq -r '.virtualMachines[0].runtime.powerState')
	[ "$power_state" = "poweredOn" ] && exit 0
done 

exit 1

