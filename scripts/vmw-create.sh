#!/bin/bash -e
# Create the VMs for the cluster

START_VM=
NO_MAC_CHECK=
if [ "$1" = "--start" ]; then
	START_VM=1; shift
fi
if [ "$1" = "--nomaccheck" ]; then
	NO_MAC_CHECK=1; shift
fi

source scripts/include_all.sh

# Load configuration
if [ -s vmware.conf ]; then
	source <(normalize-vmware-conf)  # This is needed for $VC_FOLDER
else
	aba_info "vmware.conf file not defined. Run 'aba vmw' to create it if needed"
	exit 0
fi

if [ -z "${CLUSTER_NAME:-}" ]; then
	scripts/cluster-config-check.sh
	eval "$(scripts/cluster-config.sh)" || exit 1
fi

# Read MAC address arrays
CP_MAC_ADDRS_ARRAY=($CP_MAC_ADDRS)
WKR_MAC_ADDRS_ARRAY=($WKR_MAC_ADDRS)

echo
echo_magenta "[ABA] Provisioning VMs to build the cluster ..."
echo

cluster_folder="$VC_FOLDER"
# If we are accessing vCenter (and not ESXi directly) 
if [ -n "${VC:-}" ]; then
	cluster_folder="$VC_FOLDER/$CLUSTER_NAME"
	scripts/vmw-create-folder.sh "$cluster_folder"  # This will create a folder hirerachy, if needed
fi

# Check for mac collisions? 
if [ -z "${NO_MAC_CHECK:-}" ]; then
	scripts/check-macs.sh || exit 1
fi

source <(normalize-cluster-conf)
source <(normalize-aba-conf)

verify-cluster-conf || exit 1
verify-aba-conf || exit 1

[ -z "${ISO_DATASTORE:-}" ] && ISO_DATASTORE=$GOVC_DATASTORE

# Nested & other flags
master_nested_hv=false
if [ "$WORKER_REPLICAS" -eq 0 ]; then
	master_nested_hv=true
	aba_info "Setting hardware virtualization on master nodes ..."
fi

aba_info "Setting hardware virtualization on worker nodes ..."
worker_nested_hv=true

num_ports_per_node=$PORTS_PER_NODE
max_ports_per_node=$(( num_ports_per_node - 1 ))

# Check if install is on vSphere and add memory, if needed,
# due to this 'out of disk space' issue: https://issues.redhat.com/browse/OCPBUGS-62790
[ "$GOVC_URL" ] && [ "$master_mem" -le 16 ] && master_mem=20 && aba_warning "Setting master memory to 20GB due to this bootstrap issue: https://issues.redhat.com/browse/OCPBUGS-62790" 
aba_debug master_mem=$master_mem

# Common VM creation function
create_node() {
	local role=$1         # "control" or "worker"
	local names=$2        # list of VM name suffixes
	local mac_array_name=$3
	local cpu_count=$4
	local mem_gb=$5
	local nested_hv=$6

	local -n mac_array=$mac_array_name  # nameref for easier array access
	local i=0

	for name in ${names}; do
		local vm_name="${CLUSTER_NAME}-${name}"
		local idx=$(( i * num_ports_per_node ))
		local mac=${mac_array[$idx]}

		aba_info -n "Create VM: "
		aba_info "$vm_name: [${cpu_count}C/${mem_gb}G] [$GOVC_DATASTORE] [$GOVC_NETWORK] [$mac] [$ISO_DATASTORE:images/agent-${CLUSTER_NAME}.iso] [$cluster_folder]"

		cmd="govc vm.create \
			-annotation='Created on $(date) as ${role} node for OpenShift cluster ${CLUSTER_NAME}.${base_domain} version v${ocp_version} from $(hostname):$PWD' \
			-version vmx-15 \
			-g rhel8_64Guest \
			-firmware=efi \
			-c=$cpu_count \
			-m=$(( mem_gb * 1024 )) \
			-net.adapter vmxnet3 \
			-net.address='$mac' \
			-disk-datastore=$GOVC_DATASTORE \
			-iso-datastore=$ISO_DATASTORE \
			-iso='images/agent-${CLUSTER_NAME}.iso' \
			-folder='$cluster_folder' \
			-on=false \
			$vm_name"

		aba_debug Running: $cmd
		eval $cmd  # eval needed for the ''s

		for cnt in $(seq 1 $max_ports_per_node); do
			local sub_idx=$(( idx + cnt ))
			local sub_mac=${mac_array[$sub_idx]}
			aba_info "Adding network interface [$((cnt + 1))/$num_ports_per_node] with mac address: $sub_mac"

			cmd="govc vm.network.add -vm $vm_name -net.adapter vmxnet3 -net.address '$sub_mac'"
			aba_debug Running: $cmd; eval $cmd  # eval needed for the ''s
		done

		cmd="govc device.boot -secure -vm $vm_name"
		aba_debug Running: $cmd
		$cmd

		#govc device.boot -secure -vm $vm_name

		cmd="govc vm.change -vm $vm_name \
			-e disk.enableUUID=TRUE \
			-cpu-hot-add-enabled=true \
			-memory-hot-add-enabled=true \
			-nested-hv-enabled=$nested_hv"

		aba_debug Running: $cmd
		$cmd

		aba_info "Attaching thin OS disk of size 120GB on [$GOVC_DATASTORE]"
		cmd="govc vm.disk.create \
			-vm $vm_name \
			-name $vm_name/$vm_name \
			-size 120GB \
			-thick=false \
			-ds=$GOVC_DATASTORE"

		aba_debug Running: $cmd
		$cmd

		if [ -n "${data_disk:-}" ]; then
			aba_info "Attaching a 2nd thin data disk of size $data_disk GB on [$GOVC_DATASTORE]"

			cmd="govc vm.disk.create \
				-vm $vm_name \
				-name $vm_name/${vm_name}_data \
				-size ${data_disk}GB \
				-thick=false \
				-ds=$GOVC_DATASTORE"

			aba_debug Running: $cmd
			$cmd
		fi

		if [ -n "${START_VM:-}" ]; then
			cmd="govc vm.power -on $vm_name"

			aba_debug Running: $cmd
			$cmd
		fi

		let i=$i+1
		#(( i++ ))  # For some reason was not working!
	done
}

# Invoke for masters:
create_node "control" "$CP_NAMES" CP_MAC_ADDRS_ARRAY "$master_cpu_count" "$master_mem" "$master_nested_hv"

# Invoke for workers:
create_node "worker" "$WORKER_NAMES" WKR_MAC_ADDRS_ARRAY "$worker_cpu_count" "$worker_mem" "$worker_nested_hv"

echo
if [ -n "${START_VM:-}" ]; then
	#aba_info_ok "Starting installation at $(date '+%b %e %H:%M')"
	tmp=($CP_NAMES); cp_cnt=${#tmp[*]}
	tmp=($WORKER_NAMES); wkr_cnt=${#tmp[*]}
	calculate_completion $cp_cnt $wkr_cnt
else
	aba_info_ok "To start the VMs and monitor the installation, run: aba start mon"
fi

exit 0
