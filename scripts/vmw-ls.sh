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

# List all VMs with power state
for name in $CP_NAMES $WORKER_NAMES; do
        power_state=$(govc vm.info -json ${CLUSTER_NAME}-$name | jq -r '.virtualMachines[0].runtime.powerState')
        echo ${CLUSTER_NAME}-$name $power_state
        #[ "$power_state" = "poweredOff" ] && echo $name OFF || echo $name RUNNING
done

