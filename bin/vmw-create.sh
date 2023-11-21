#!/bin/bash -e

[ ! "$1" ] && echo Usage: `basename $0` --dir directory && exit 1
[ "$DEBUG_ABA" ] && set -x

common/scripts/validate.sh $@

if [ ! "$CLUSTER_NAME" ]; then
	eval `common/scripts/cluster-config.sh $@ || exit 1`
fi

CP_MAC_ADDRESSES_ARRAY=($CP_MAC_ADDRESSES)
WORKER_MAC_ADDRESSES_ARRAY=($WORKER_MAC_ADDRESSES)

####common/scripts/cluster-config.sh $@ 

echo "Checking if the command 'arp' is availiable ..."
which arp >/dev/null 2>&1 || sudo yum install net-tools -y 

# Delete arp cache 
#arp -an | cut -d\( -f2 | cut -d\) -f1 | xargs -L1 sudo arp -d
#ping -c2 -b 10.0.1.255
#echo arp
#arp -an 
#sleep 1

echo Checking mac addresses already in use ...
arp -an > /tmp/.all.mac 
for mac in $CP_MAC_ADDRESSES
do
	echo checking $mac ...
	if grep " $mac " /tmp/.all.mac; then
		echo 
		echo "WARNING:"
		echo "Mac address $mac is already in use.  If you're running multiple OCP clusters, ensure no mac/ip addresses overlap!" 
		echo "Change 'mac_prefix' in $1.src/aba.conf and run the command again."
		#rm -f $1.src/agent-config.yaml $1.src/install-config.yaml
		exit 
	fi
done

# Read in the cpu and mem values 
[ -s $1/aba.conf ] && . $1/aba.conf || exit 1

. ~/.vmware.conf
[ ! "$ISO_DATASTORE" ] && ISO_DATASTORE=$GOVC_DATASTORE

# If we accessing vCenter (and not ESXi directly) 
[ "$VC" ] && echo Create folder: $FOLDER
[ "$VC" ] && govc folder.create $FOLDER || true

# Check and increase CPU count for SNO, if needed
[ $CP_REPLICAS -eq 1 -a $WORKER_REPLICAS -eq 0 -a $master_cpu_count -lt 16 ] && master_cpu_count=16   # For SNO

i=1
for name in $CP_NAMES ; do
	a=`expr $i-1`

	echo Create master: $name VM with ${CP_MAC_ADDRESSES_ARRAY[$a]} images/agent-${CLUSTER_NAME}.iso $FOLDER/${CLUSTER_NAME}-$name
	govc vm.create \
		-g rhel9_64Guest \
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

