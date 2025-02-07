#!/bin/bash 
# Stop the VMs gracefully with vmware system shutdown

[ "$DEBUG_ABA" ] && echo "Running: $0 $*" >&2

source scripts/include_all.sh

scripts/install-govc.sh

while [ "$1" ]
do
	if [ "$1" = "--wait" ]; then
		wait=1
		shift
	elif [ "$1" = "--workers" ]; then
		workers_only=1
		shift
	elif [ "$1" = "--debug" ]; then
		set -x
		shift
	else
		echo "$(basename $0): Warning: ignoring unknown option $1" >&2
		shift
	fi
done

if [ -s vmware.conf ]; then
	source <(normalize-vmware-conf)  # This is needed for $VC_FOLDER
else
	echo "vmware.conf file not defined. Run 'aba vmw' to create it if needed"
	exit 0
fi

if [ ! "$CLUSTER_NAME" ]; then
	scripts/cluster-config-check.sh
	eval `scripts/cluster-config.sh || exit 1`
fi

source <(normalize-aba-conf)  # Fetch the 'ask' param

cluster_folder=$VC_FOLDER/$CLUSTER_NAME

hosts="$WORKER_NAMES $CP_NAMES"
[ "$workers_only" ] && hosts="$WORKER_NAMES"
[ ! "$hosts" ] && hosts="$CP_NAMES"

if [ "$ask" ]; then
	echo
	for name in $hosts; do
		[ "$VC" ] && echo $cluster_folder/${CLUSTER_NAME}-$name || echo ${CLUSTER_NAME}-$name
	done

	ask "Stop the above virtual machine(s)" || exit 1
fi

for name in $hosts; do
	# Shut down guest if vmware tools exist
	#govc vm.power -s ${CLUSTER_NAME}-$name || true
	govc vm.power -s ${CLUSTER_NAME}-$name 
done

if [ "$wait" ]; then
	echo_cyan "Waiting for nodes to power down ..."

	hosts_off=
	while [ ! "$hosts_off" ];
	do
		for name in $hosts; do
			vm_info=$(govc vm.info -json ${CLUSTER_NAME}-$name)
			[ ! "$vm_info" ] && continue

			power_state=$(echo "$vm_info" | jq -r '.virtualMachines[0].runtime.powerState')
			[ "$power_state" == "null" ] && continue

			[ "$power_state" == "poweredOn" ] && hosts_off= && break
			[ "$power_state" == "poweredOff" ] && hosts_off=1
		done

		[ "$hosts_off" ] && exit 0

		sleep 10
	done
	#until make -s ls | grep poweredOn | wc -l | grep -q ^0$; do sleep 10; done
fi

exit 0
