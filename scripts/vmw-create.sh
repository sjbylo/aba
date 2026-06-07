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

aba_info "Provisioning VMs to build the cluster ..."

# Pre-flight: verify datastore and network exist before attempting VM creation
if ! govc datastore.info "$GOVC_DATASTORE" >/dev/null 2>&1; then
	aba_abort \
		"Datastore '$GOVC_DATASTORE' not found." \
		"Available datastores: $(govc datastore.ls 2>/dev/null | tr '\n' ', ')" \
		"Fix GOVC_DATASTORE in vmware.conf and try again."
fi
if [ "${VC:-}" ]; then
	if ! govc find / -type Network -name "$GOVC_NETWORK" 2>/dev/null | grep -q .; then
		aba_abort \
			"Network '$GOVC_NETWORK' not found." \
			"Available networks: $(govc ls network/ 2>/dev/null | xargs -I{} basename {} | tr '\n' ', ')" \
			"Fix GOVC_NETWORK in vmware.conf and try again."
	fi
else
	# ESXi standalone: govc find may not list port groups in the MOB.
	# Use host.portgroup.info which queries host config directly.
	if ! govc host.portgroup.info "$GOVC_NETWORK" >/dev/null 2>&1; then
		aba_abort \
			"Network '$GOVC_NETWORK' not found." \
			"Available networks: $(govc host.portgroup.info 2>/dev/null | grep '^Name:' | sed 's/Name: *//' | tr '\n' ', ')" \
			"Fix GOVC_NETWORK in vmware.conf and try again."
	fi
fi

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

source <(normalize-aba-conf)
source <(normalize-cluster-conf)

verify-cluster-conf || exit 1
verify-aba-conf || aba_abort "$_ABA_CONF_ERR"

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

# On vSphere, agent-based installs with <=16GB master RAM can fail during
# bootstrap with "no space left on device" (OCPBUGS-62790, Red Hat KCS 7133039).
if [ "$GOVC_URL" ] && [ "$master_mem" -le 16 ]; then
	if ask "Increase master memory from ${master_mem}GB to 20GB to avoid bootstrap disk-space issue (OCPBUGS-62790)"; then
		master_mem=20
	else
		aba_warning "Keeping master memory at ${master_mem}GB -- bootstrap may fail with 'no space left on device'"
	fi
fi
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
		local vm_name=$(vm_name "$CLUSTER_NAME" "$name")
		local idx=$(( i * num_ports_per_node ))
		local mac=${mac_array[$idx]}

		aba_info "Create VM: $vm_name: [${cpu_count}C/${mem_gb}G] [$GOVC_DATASTORE] [$GOVC_NETWORK] [$mac] [$ISO_DATASTORE:images/agent-${CLUSTER_NAME}.iso] [$cluster_folder]"

		local annotation
		annotation=$(_vm_annotation "$role")

		cmd="govc vm.create \
			-annotation='$annotation' \
			-version vmx-15 \
			-g rhel8_64Guest \
			-firmware=efi \
			-c=$cpu_count \
			-m=$(( mem_gb * 1024 )) \
			-net.adapter vmxnet3 \
			-net.address='$mac' \
			-disk-datastore=$GOVC_DATASTORE \
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

		# Attach ISO via explicit cdrom.add + cdrom.insert rather than the
		# vm.create -iso shortcut. Why:
		#   1. vm.create -iso silently leaves the CD-ROM disconnected when the
		#      ISO datastore isn't immediately accessible (seen with NFS, but
		#      can affect VMFS/vSAN too). The VM then boots to EFI Boot Manager
		#      with no indication of what went wrong.
		#   2. Explicit cdrom.insert returns a clear error on failure, allowing
		#      retry and a meaningful abort message.
		#   3. This matches the robust pattern used in tools/create-template.sh.
		local _cdrom_dev _cdrom_err _iso_path="images/agent-${CLUSTER_NAME}.iso"
		local _cdrom_out
		_cdrom_out=$(govc device.cdrom.add -vm "$vm_name" 2>&1)
		local _rc=$?
		_cdrom_dev=$(echo "$_cdrom_out" | grep -o 'cdrom-[0-9]*')
		aba_debug "govc device.cdrom.add -vm $vm_name: rc=$_rc out=$_cdrom_out dev=$_cdrom_dev"

		if [ $_rc -ne 0 ] || [ -z "$_cdrom_dev" ]; then
			aba_abort "Failed to add CD-ROM device on $vm_name: $_cdrom_out"
		fi

		local _insert_ok=""
		for _try in 1 2 3; do
			_cdrom_err=$(govc device.cdrom.insert -vm "$vm_name" -device "$_cdrom_dev" \
				-ds "$ISO_DATASTORE" "$_iso_path" 2>&1)
			local _rc=$?
			aba_debug "govc device.cdrom.insert -vm $vm_name -device $_cdrom_dev -ds $ISO_DATASTORE $_iso_path (attempt $_try): rc=$_rc $_cdrom_err"
			if [ $_rc -eq 0 ]; then
				_insert_ok=1
				break
			fi
			aba_warning "CD-ROM insert failed on $vm_name (attempt $_try/3): $_cdrom_err"
			sleep 3
		done
		if [ -z "$_insert_ok" ]; then
			aba_abort "Failed to insert ISO into CD-ROM on $vm_name after 3 attempts. Check ISO datastore ($ISO_DATASTORE) accessibility."
		fi

		# Verify the CD-ROM is connected (startConnected=true) after insert.
		# On a powered-off VM, "connected" is always false (vSphere behaviour)
		# but "startConnected" must be true for the ISO to attach at power-on.
		local _verify_out _start_conn
		_verify_out=$(govc device.info -json -vm "$vm_name" "$_cdrom_dev" 2>&1) || true
		_start_conn=$(echo "$_verify_out" | grep -E '"(start)?[Cc]onnected"' | tr -d ' ,')
		aba_debug "CD-ROM verify on $vm_name $_cdrom_dev: $_start_conn"
		if ! echo "$_verify_out" | grep -q '"startConnected": true'; then
			aba_warning "CD-ROM $_cdrom_dev on $vm_name: startConnected is NOT true after insert -- VM may fail to boot from ISO"
		fi

		if [ -n "${START_VM:-}" ]; then
			cmd="govc vm.power -on $vm_name"
			aba_debug "Running: $cmd"
			$cmd
		fi

		let i=$i+1
	done
}

# Invoke for masters:
create_node "control" "$CP_NAMES" CP_MAC_ADDRS_ARRAY "$master_cpu_count" "$master_mem" "$master_nested_hv"

# Invoke for workers:
create_node "worker" "$WORKER_NAMES" WKR_MAC_ADDRS_ARRAY "$worker_cpu_count" "$worker_mem" "$worker_nested_hv"

if [ -n "${START_VM:-}" ]; then
	cp_arr=($CP_NAMES);		cp_cnt=${#cp_arr[*]}
	wkr_arr=($WORKER_NAMES);	wkr_cnt=${#wkr_arr[*]}

	# Output VM start time and estimated end time
	calculate_and_show_completion $cp_cnt $wkr_cnt
else
	aba_info_ok "To start the VMs and monitor the installation, run: aba start mon"
fi

exit 0
