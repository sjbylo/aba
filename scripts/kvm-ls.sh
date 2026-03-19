#!/bin/bash
# Display the VMs and their state on the KVM host

source scripts/include_all.sh

aba_debug "Starting: $0 $* at $(date) in dir: $PWD"

if [ -s kvm.conf ]; then
	ensure_virsh
	source <(normalize-kvm-conf)
else
	aba_info "kvm.conf file not defined. Run 'aba kvm' to create it if needed"
	exit 0
fi

if [ ! "$CLUSTER_NAME" ]; then
	scripts/cluster-config-check.sh
	eval "$(scripts/cluster-config.sh)" || exit 1
fi

header="Name CPU Memory State"

output=
for name in $CP_NAMES $WORKER_NAMES; do
	vm=$(vm_name "$CLUSTER_NAME" "$name")
	info=$(virsh -c "$LIBVIRT_URI" dominfo "$vm" 2>/dev/null) || continue

	state=$(echo "$info" | awk '/^State:/ {$1=""; print substr($0,2)}')
	num_cpu=$(echo "$info" | awk '/^CPU\(s\):/ {print $2}')
	memory_kb=$(echo "$info" | awk '/^Max memory:/ {print $3}')
	[ "$memory_kb" ] && memory_gb=$(( memory_kb / 1048576 )) || memory_gb="?"

	output="$output\n${vm} ${num_cpu} ${memory_gb}GB $state"
done

if [ "$output" ]; then
	echo -e "$header\n$output" | column -t
else
	echo "No resources"
fi
