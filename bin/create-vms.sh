#!/bin/bash -e

common/scripts/validate.sh $@

if [ ! "$CLUSTER_NAME" ]; then
	eval `common/scripts/cluster-config.sh $@ || exit 1`
fi

CP_MAC_ADDRESSES_ARRAY=($CP_MAC_ADDRESSES)
WORKER_MAC_ADDRESSES_ARRAY=($WORKER_MAC_ADDRESSES)

. ~/.vmware.conf

[ "$VC" ] && echo Create folder: $FOLDER
[ "$VC" ] && govc folder.create $FOLDER || true

# Remember to put the VMs on the local fast storage!
# The vm template is configured to use CDROM from shared storage (i.e. reachable by all VMs).

# Set the cpu and ram for the masters
cpu=4
[ $CP_REPLICAS -eq 1 -a $WORKER_REPLICAS -eq 0 ] && cpu=8   # For SNO

i=1
for name in $CP_NAMES ; do
	a=`expr $i-1`

	echo Create master: $name VM with ${CP_MAC_ADDRESSES_ARRAY[$a]} images/agent-${CLUSTER_NAME}.iso $FOLDER/${CLUSTER_NAME}-$name
	govc vm.create \
		-g rhel9_64Guest \
		-c=$cpu \
		-m=`expr 16 \* 1024` \
		-disk-datastore=$GOVC_DATASTORE \
		-net.adapter vmxnet3 \
		-net.address="${CP_MAC_ADDRESSES_ARRAY[$a]}" \
		-iso-datastore=$ISO_DATASTORE \
		-iso="images/agent-${CLUSTER_NAME}.iso" \
		-folder="$FOLDER" \
		-on=false \
		 ${CLUSTER_NAME}-$name

	govc vm.change -vm ${CLUSTER_NAME}-$name -e disk.enableUUID=TRUE

	echo Create and attach disk
	govc vm.disk.create \
		-vm ${CLUSTER_NAME}-$name \
		-name ${CLUSTER_NAME}-$name/${CLUSTER_NAME}-$name \
		-size 120GB \
		-thick=false \
		-ds=$GOVC_DATASTORE
	let i=$i+1
done

i=1
for name in $WORKER_NAMES ; do
	a=`expr $i-1`

	echo Create worker: $name VM with ${WORKER_MAC_ADDRESSES_ARRAY[$a]} images/agent-${CLUSTER_NAME}.iso $FOLDER/${CLUSTER_NAME}-$name
	govc vm.create \
		-g rhel9_64Guest \
		-c=8 \
		-m=`expr 24 \* 1024` \
		-net.adapter vmxnet3 \
		-disk-datastore=$GOVC_DATASTORE \
		-net.address="${WORKER_MAC_ADDRESSES_ARRAY[$a]}" \
		-iso-datastore=$ISO_DATASTORE \
		-iso="images/agent-${CLUSTER_NAME}.iso" \
		-folder="$FOLDER" \
		-on=false \
		 ${CLUSTER_NAME}-$name

	govc vm.change -vm ${CLUSTER_NAME}-$name -e disk.enableUUID=TRUE

	echo Create and attach disk
	govc vm.disk.create \
		-vm ${CLUSTER_NAME}-$name \
		-name ${CLUSTER_NAME}-$name/${CLUSTER_NAME}-$name \
		-size 120GB \
		-thick=false \
		-ds=$GOVC_DATASTORE
	let i=$i+1
done

