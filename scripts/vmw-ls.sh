#!/bin/bash 

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

header="Name CPU Memory State"

output=
# List all VMs with cpu, ram and power state
for name in $CP_NAMES $WORKER_NAMES; do
	power_state=$(govc vm.info -json ${CLUSTER_NAME}-$name | jq -r '.virtualMachines[0].runtime.powerState')
	[ "$power_state" = "null" ] && continue
	num_cpu=$(govc vm.info -json ${CLUSTER_NAME}-$name | jq -r '.virtualMachines[0].config.hardware.numCPU')
	memory_mb=$(govc vm.info -json ${CLUSTER_NAME}-$name | jq -r '.virtualMachines[0].config.hardware.memoryMB')

	output="$output\n${CLUSTER_NAME}-$name ${num_cpu} $(expr $memory_mb / 1024)GB $power_state"
done 

[ "$output" ] && echo -e "$header\n$output" | column -t ### || echo "No resources"

