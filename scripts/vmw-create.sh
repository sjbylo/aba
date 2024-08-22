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
	echo "vmware.conf file not defined. Run 'make vmw' to create it if needed"
	exit 0
fi

if [ ! "$CLUSTER_NAME" ]; then
	scripts/cluster-config-check.sh
	eval `scripts/cluster-config.sh || exit 1`
fi

CP_MAC_ADDRESSES_ARRAY=($CP_MAC_ADDRESSES)
WKR_MAC_ADDRESSES_ARRAY=($WKR_MAC_ADDRESSES)

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

[ ! "$ISO_DATASTORE" ] && ISO_DATASTORE=$GOVC_DATASTORE

#if [ "$VC" ]; then
	###echo Create folder: $cluster_folder
	###scripts/vmw-create-folder.sh $cluster_folder  # This will create a folder hirerachy, if needed
	####govc folder.create $cluster_folder 
#fi

# Check and increase CPU count for SNO, if needed
##[ $CP_REPLICAS -eq 1 -a $WORKER_REPLICAS -eq 0 -a $master_cpu_count -lt 4 ] && master_cpu_count=4 && echo Increasing cpu count to 4 for SNO ...
[ $CP_REPLICAS -eq 1 -a $WORKER_REPLICAS -eq 0 -a $master_cpu_count -lt 4 ] && echo "Warning: CPU count for SNO should be set to 4 (cores) for full support."

# Enable hardware virt on the workers only (or also masters for 'scheduling enabled')
master_nested_hv=false
[ $WORKER_REPLICAS -eq 0 ] && master_nested_hv=true && echo Setting hardware virt on master nodes ...
worker_nested_hv=true

i=1
for name in $CP_NAMES ; do
	a=`expr $i-1`

	vm_name=${CLUSTER_NAME}-$name
	mac=${CP_MAC_ADDRESSES_ARRAY[$a]}

	echo "Create VM: $vm_name: [$master_cpu_count/$master_mem] [$GOVC_DATASTORE] [$mac] [$ISO_DATASTORE:images/agent-${CLUSTER_NAME}.iso] [$cluster_folder] [$GOVC_NETWORK]"
	govc vm.create \
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
	mac=${WKR_MAC_ADDRESSES_ARRAY[$a]}

	echo "Create VM: $vm_name: [$master_cpu_count/$master_mem] [$GOVC_DATASTORE] [$mac] [$ISO_DATASTORE:images/agent-${CLUSTER_NAME}.iso] [$cluster_folder] [$GOVC_NETWORK]"
	govc vm.create \
		-version vmx-15 \
		-g rhel8_64Guest \
		-firmware=efi \
		-c=$worker_cpu_count \
		-m=`expr $worker_mem \* 1024` \
		-net.adapter vmxnet3 \
		-disk-datastore=$GOVC_DATASTORE \
		-net.address="$mac" \
		-iso-datastore=$ISO_DATASTORE \
		-iso="images/agent-${CLUSTER_NAME}.iso" \
		-folder="$cluster_folder" \
		-on=false \
		 $vm_name

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

