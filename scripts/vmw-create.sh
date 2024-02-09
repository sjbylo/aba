#!/bin/bash 

source scripts/include_all.sh

[ "$1" = "--start" ] && START_VM=1 && shift

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

CP_MAC_ADDRESSES_ARRAY=($CP_MAC_ADDRESSES)
WORKER_MAC_ADDRESSES_ARRAY=($WORKER_MAC_ADDRESSES)

scripts/check-macs.sh || exit 

# Read in the cpu and mem values 
source <(normalize-cluster-conf) 

[ ! "$ISO_DATASTORE" ] && ISO_DATASTORE=$GOVC_DATASTORE

# If we are accessing vCenter (and not ESXi directly) 
if [ "$VC" ]; then
	echo Create folder: $FOLDER
	govc folder.create $FOLDER 
fi

# Check and increase CPU count for SNO, if needed
[ $CP_REPLICAS -eq 1 -a $WORKER_REPLICAS -eq 0 -a $master_cpu_count -lt 16 ] && master_cpu_count=16 && echo Increasing cpu count to 16 for SNO ...

i=1
for name in $CP_NAMES ; do
	a=`expr $i-1`

	echo "Create master: [$name] VM with [${CP_MAC_ADDRESSES_ARRAY[$a]}] [$ISO_DATASTORE:images/agent-${CLUSTER_NAME}.iso] [$FOLDER/${CLUSTER_NAME}-$name]"
	govc vm.create \
		-g rhel8_64Guest \
		-firmware=efi \
		-c=$master_cpu_count \
		-m=`expr $master_mem \* 1024` \
		-disk-datastore=$GOVC_DATASTORE \
		-net.adapter vmxnet3 \
		-net.address="${CP_MAC_ADDRESSES_ARRAY[$a]}" \
		-iso-datastore=$ISO_DATASTORE \
		-iso="images/agent-${CLUSTER_NAME}.iso" \
		-folder="$FOLDER" \
		-on=false \
		 ${CLUSTER_NAME}-$name

	govc device.boot -secure -vm ${CLUSTER_NAME}-$name

	govc vm.change -vm ${CLUSTER_NAME}-$name -e disk.enableUUID=TRUE

	echo "Create and attach disk on [$GOVC_DATASTORE]"
	govc vm.disk.create \
		-vm ${CLUSTER_NAME}-$name \
		-name ${CLUSTER_NAME}-$name/${CLUSTER_NAME}-$name \
		-size 120GB \
		-thick=false \
		-ds=$GOVC_DATASTORE

	[ "$START_VM" ] && govc vm.power -on ${CLUSTER_NAME}-$name

	let i=$i+1
done

i=1
for name in $WORKER_NAMES ; do
	a=`expr $i-1`

	echo "Create master: [$name] VM with [${WORKER_MAC_ADDRESSES_ARRAY[$a]}] [$ISO_DATASTORE:images/agent-${CLUSTER_NAME}.iso] [$FOLDER/${CLUSTER_NAME}-$name]"
	govc vm.create \
		-g rhel8_64Guest \
		-firmware=efi \
		-c=$worker_cpu_count \
		-m=`expr $worker_mem \* 1024` \
		-net.adapter vmxnet3 \
		-disk-datastore=$GOVC_DATASTORE \
		-net.address="${WORKER_MAC_ADDRESSES_ARRAY[$a]}" \
		-iso-datastore=$ISO_DATASTORE \
		-iso="images/agent-${CLUSTER_NAME}.iso" \
		-folder="$FOLDER" \
		-on=false \
		 ${CLUSTER_NAME}-$name

	govc device.boot -secure -vm ${CLUSTER_NAME}-$name

	govc vm.change -vm ${CLUSTER_NAME}-$name -e disk.enableUUID=TRUE

	echo "Create and attach disk on [$GOVC_DATASTORE]"
	govc vm.disk.create \
		-vm ${CLUSTER_NAME}-$name \
		-name ${CLUSTER_NAME}-$name/${CLUSTER_NAME}-$name \
		-size 120GB \
		-thick=false \
		-ds=$GOVC_DATASTORE

	[ "$START_VM" ] && govc vm.power -on ${CLUSTER_NAME}-$name

	let i=$i+1
done

