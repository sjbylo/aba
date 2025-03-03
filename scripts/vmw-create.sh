#!/bin/bash -e
# Create the VMs for the cluster

source scripts/include_all.sh

START_VM=
NO_MAC=
[ "$1" = "--start" ] && START_VM=1 && shift
[ "$1" = "--nomac" ] && NO_MAC=1 && shift

[ "$1" ] && set -x

if [ -s vmware.conf ]; then
	source <(normalize-vmware-conf)  # This is needed for $VC_FOLDER
else
	echo_red "vmware.conf file not defined. Run 'aba vmw' to create it if needed" >&2

	exit 0
fi

if [ ! "$CLUSTER_NAME" ]; then
	scripts/cluster-config-check.sh
	eval `scripts/cluster-config.sh || exit 1`
fi

CP_MAC_ADDR_ARRAY=($CP_MAC_ADDR)
CP_MAC_ADDR_ARRAY2=($CP_MAC_ADDR_2ND)
WKR_MAC_ADDR_ARRAY=($WKR_MAC_ADDR)
WKR_MAC_ADDR_ARRAY2=($WKR_MAC_ADDR_2ND)

echo
echo_magenta "Provisioning VMs to build the cluster ..."
echo

# FIXME: Check if folder $VC_FOLDER already exists or not.  Should we create it but never delete it.
# Only the cluster folder shouod be created and deleted by aba
#cluster_folder=$VC_FOLDER  # FIXME - this should be folder/cluster-name
#if [ "$VC_FOLDER" != "/ha-datacenter/vm" ]; then
# If we are accessing vCenter (and not ESXi directly) 
if [ "$VC" ]; then
	cluster_folder=$VC_FOLDER/$CLUSTER_NAME
	scripts/vmw-create-folder.sh $cluster_folder  # This will create a folder hirerachy, if needed
else
	cluster_folder=$VC_FOLDER
fi

if [ ! "$NO_MAC" ]; then
	scripts/check-macs.sh || exit 
fi

# Read in the cpu and mem values 
source <(normalize-cluster-conf) 

verify-cluster-conf || exit 1

[ ! "$ISO_DATASTORE" ] && ISO_DATASTORE=$GOVC_DATASTORE

#if [ "$VC" ]; then
	###echo Create folder: $cluster_folder
	###scripts/vmw-create-folder.sh $cluster_folder  # This will create a folder hirerachy, if needed
	####govc folder.create $cluster_folder 
#fi

# Check and warn about CPU count for SNO
[ $CP_REPLICAS -eq 1 -a $WORKER_REPLICAS -eq 0 -a $master_cpu_count -lt 8 ] && \
	echo_magenta "Note: The minimum requirement for SNO in production is 8 vCPU and 16 GB RAM." 

# Enable hardware virt on the workers only (or also masters for 'scheduling enabled')
master_nested_hv=false
[ $WORKER_REPLICAS -eq 0 ] && master_nested_hv=true && echo Setting hardware virtualization on master nodes ...
echo Setting hardware virtualization on worker nodes ...
worker_nested_hv=true

i=1
for name in $CP_NAMES ; do
	a=`expr $i-1`

	vm_name=${CLUSTER_NAME}-$name
	mac=${CP_MAC_ADDR_ARRAY[$a]}
	mac2=${CP_MAC_ADDR_ARRAY2[$a]}

	echo_cyan -n "Create VM: "
	echo "$vm_name: [$master_cpu_count/$master_mem] [$GOVC_DATASTORE] [$mac] [$GOVC_NETWORK] [$ISO_DATASTORE:images/agent-${CLUSTER_NAME}.iso] [$cluster_folder]"
	govc vm.create \
		-annotation="Created on '$(date)' as control node for OCP cluster $cluster_name.$base_domain version v$ocp_version" \
		-version vmx-15 \
		-g rhel8_64Guest \
		-firmware=efi \
		-c=$master_cpu_count \
		-m=`expr $master_mem \* 1024` \
		-disk-datastore=$GOVC_DATASTORE \
		-net.adapter vmxnet3 \
		-net.address="$mac" \
		-iso-datastore=$ISO_DATASTORE \
		-iso="images/agent-${CLUSTER_NAME}.iso" \
		-folder="$cluster_folder" \
		-on=false \
		 $vm_name

	if [ "$mac2" ]; then
		echo "Adding 2nd network interface with mac address: $mac2"
		govc vm.network.add -vm $vm_name -net.adapter vmxnet3 -net.address $mac2
	fi

	govc device.boot -secure -vm $vm_name

	govc vm.change -vm $vm_name -e disk.enableUUID=TRUE -cpu-hot-add-enabled=true -memory-hot-add-enabled=true -nested-hv-enabled=$master_nested_hv

	echo "Create and attach thin OS disk on [$GOVC_DATASTORE]"
	govc vm.disk.create \
		-vm $vm_name \
		-name $vm_name/$vm_name \
		-size 120GB \
		-thick=false \
		-ds=$GOVC_DATASTORE

	if [ "$data_disk" ]; then
		echo "Create and attach a 2nd thin data disk of size $data_disk GB on [$GOVC_DATASTORE]"
		govc vm.disk.create \
			-vm $vm_name \
			-name $vm_name/${vm_name}_data \
			-size ${data_disk}GB \
			-thick=false \
			-ds=$GOVC_DATASTORE
	fi

	[ "$START_VM" ] && govc vm.power -on $vm_name

	let i=$i+1
done

i=1
for name in $WORKER_NAMES ; do
	a=`expr $i-1`

	vm_name=${CLUSTER_NAME}-$name
	mac=${WKR_MAC_ADDR_ARRAY[$a]}
	mac2=${WKR_MAC_ADDR_ARRAY2[$a]}

	echo_cyan -n "Create VM: "
	echo "$vm_name: [$worker_cpu_count/$worker_mem] [$GOVC_DATASTORE] [$GOVC_NETWORK] [$mac] [$ISO_DATASTORE:images/agent-${CLUSTER_NAME}.iso] [$cluster_folder]"
	govc vm.create \
		-annotation="Created on '$(date)' as control node for OCP cluster $cluster_name.$base_domain version v$ocp_version" \
		-version vmx-15 \
		-g rhel8_64Guest \
		-firmware=efi \
		-c=$worker_cpu_count \
		-m=`expr $worker_mem \* 1024` \
		-disk-datastore=$GOVC_DATASTORE \
		-net.adapter vmxnet3 \
		-net.address="$mac" \
		-iso-datastore=$ISO_DATASTORE \
		-iso="images/agent-${CLUSTER_NAME}.iso" \
		-folder="$cluster_folder" \
		-on=false \
		 $vm_name

	if [ "$mac2" ]; then
		echo "Adding 2nd network interface with mac address: $mac2"
		govc vm.network.add -vm $vm_name -net.adapter vmxnet3 -net.address $mac2
	fi

	govc device.boot -secure -vm $vm_name

	govc vm.change -vm $vm_name -e disk.enableUUID=TRUE -cpu-hot-add-enabled=true -memory-hot-add-enabled=true -nested-hv-enabled=$worker_nested_hv

	echo "Create and attach thin OS disk on [$GOVC_DATASTORE]"
	govc vm.disk.create \
		-vm $vm_name \
		-name $vm_name/$vm_name \
		-size 120GB \
		-thick=false \
		-ds=$GOVC_DATASTORE

	if [ "$data_disk" ]; then
		echo "Create and attach a 2nd thin data disk of size $data_disk GB on [$GOVC_DATASTORE]"
		govc vm.disk.create \
			-vm $vm_name \
			-name $vm_name/${vm_name}_data \
			-size ${data_disk}GB \
			-thick=false \
			-ds=$GOVC_DATASTORE
	fi

	[ "$START_VM" ] && govc vm.power -on $vm_name

	let i=$i+1
done

echo
echo Now run: aba mon
