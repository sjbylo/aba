#!/bin/bash -e
# Create the VMs for the cluster on the KVM host

START_VM=
NO_MAC_CHECK=
if [ "$1" = "--start" ]; then
	START_VM=1; shift
fi
if [ "$1" = "--nomaccheck" ]; then
	NO_MAC_CHECK=1; shift
fi

source scripts/include_all.sh

if [ -s kvm.conf ]; then
	ensure_virsh
	source <(normalize-kvm-conf)
else
	aba_info "kvm.conf file not defined. Run 'aba kvm' to create it if needed"
	exit 0
fi

if [ -z "${CLUSTER_NAME:-}" ]; then
	scripts/cluster-config-check.sh
	eval "$(scripts/cluster-config.sh)" || exit 1
fi

CP_MAC_ADDRS_ARRAY=($CP_MAC_ADDRS)
WKR_MAC_ADDRS_ARRAY=($WKR_MAC_ADDRS)

aba_info "Provisioning VMs on KVM host ..."

if [ -z "${NO_MAC_CHECK:-}" ]; then
	scripts/check-macs.sh || exit 1
fi

source <(normalize-aba-conf)
source <(normalize-cluster-conf)

verify-cluster-conf || exit 1
verify-aba-conf || aba_abort "$_ABA_CONF_ERR"

master_nested_hv=
if [ "$WORKER_REPLICAS" -eq 0 ]; then
	master_nested_hv=1
	aba_info "Setting CPU host-passthrough on master nodes ..."
fi

aba_info "Setting CPU host-passthrough on worker nodes ..."
worker_nested_hv=1

num_ports_per_node=$PORTS_PER_NODE

iso_path="${KVM_STORAGE_POOL}/agent-${CLUSTER_NAME}.iso"

create_node() {
	local role=$1
	local names=$2
	local mac_array_name=$3
	local cpu_count=$4
	local mem_gb=$5
	local nested_hv=$6

	local -n mac_array=$mac_array_name
	local i=0

	for name in ${names}; do
		local vm_name="${CLUSTER_NAME}-${name}"
		local idx=$(( i * num_ports_per_node ))
		local mac=${mac_array[$idx]}

		local disk_path="${KVM_STORAGE_POOL}/${vm_name}.qcow2"
		local mem_mb=$(( mem_gb * 1024 ))

		aba_info "Create VM: $vm_name: [${cpu_count}C/${mem_gb}G] [${KVM_NETWORK}] [$mac] [${iso_path}]"

		local cpu_model="host-passthrough"
		local extra_cpu_args=""
		if [ "$nested_hv" ]; then
			extra_cpu_args="--cpu ${cpu_model}"
		fi

		local extra_disk_args=""
		if [ -n "${data_disk:-}" ]; then
			extra_disk_args="--disk path=${KVM_STORAGE_POOL}/${vm_name}_data.qcow2,size=${data_disk},format=qcow2,bus=virtio"
			aba_info "Adding a 2nd data disk of size ${data_disk}GB"
		fi

		local net_args="--network bridge=${KVM_NETWORK},model=virtio,mac=${mac}"
		local max_ports=$(( num_ports_per_node - 1 ))
		for cnt in $(seq 1 $max_ports); do
			local sub_idx=$(( idx + cnt ))
			local sub_mac=${mac_array[$sub_idx]}
			net_args="$net_args --network bridge=${KVM_NETWORK},model=virtio,mac=${sub_mac}"
			aba_info "Adding network interface [$((cnt + 1))/${num_ports_per_node}] with mac address: $sub_mac"
		done

		virt-install \
			--connect "$LIBVIRT_URI" \
			--name "$vm_name" \
			--ram "$mem_mb" \
			--vcpus "$cpu_count" \
			--disk "path=${disk_path},size=120,format=qcow2,bus=virtio" \
			$extra_disk_args \
			--cdrom "$iso_path" \
			$net_args \
			--os-variant rhel9-unknown \
			--boot uefi \
			--check disk_size=off \
			$extra_cpu_args \
			--noautoconsole --noreboot

		if [ -n "${START_VM:-}" ]; then
			virsh -c "$LIBVIRT_URI" start "$vm_name"
			virsh -c "$LIBVIRT_URI" autostart "$vm_name"
		fi

		let i=$i+1
	done
}

create_node "control" "$CP_NAMES" CP_MAC_ADDRS_ARRAY "$master_cpu_count" "$master_mem" "$master_nested_hv"

create_node "worker" "$WORKER_NAMES" WKR_MAC_ADDRS_ARRAY "$worker_cpu_count" "$worker_mem" "$worker_nested_hv"

if [ -n "${START_VM:-}" ]; then
	cp_arr=($CP_NAMES);		cp_cnt=${#cp_arr[*]}
	wkr_arr=($WORKER_NAMES);	wkr_cnt=${#wkr_arr[*]}

	calculate_and_show_completion $cp_cnt $wkr_cnt
else
	aba_info_ok "To start the VMs and monitor the installation, run: aba start mon"
fi

exit 0
