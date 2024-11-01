#!/bin/bash 
# Disply the VMs and their state

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
	vm_info=$(govc vm.info -json ${CLUSTER_NAME}-$name)
	[ ! "$vm_info" ] && continue

	power_state=$(echo "$vm_info" | jq -r '.virtualMachines[0].runtime.powerState')
	[ "$power_state" == "null" ] && continue

	num_cpu=$(echo "$vm_info" | jq -r '.virtualMachines[0].config.hardware.numCPU')
	memory_mb=$(echo "$vm_info" | jq -r '.virtualMachines[0].config.hardware.memoryMB')
	[ "$memory_mb" -a "$memory_mb" != "null" ] && memory_gb=$(expr $memory_mb / 1024)

	output="$output\n${CLUSTER_NAME}-$name ${num_cpu} ${memory_gb}GB $power_state"
done 

if [ "$output" ]; then
	echo -e "$header\n$output" | column -t
else
	echo "No resources"
fi

