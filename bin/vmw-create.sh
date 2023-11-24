#!/bin/bash -e

[ ! "$1" ] && echo Usage: `basename $0` --dir directory && exit 1
[ "$DEBUG_ABA" ] && set -x

if [ ! "$CLUSTER_NAME" ]; then
	eval `common/scripts/cluster-config.sh $@ || exit 1`
fi

bin/init.sh $@

CP_MAC_ADDRESSES_ARRAY=($CP_MAC_ADDRESSES)
WORKER_MAC_ADDRESSES_ARRAY=($WORKER_MAC_ADDRESSES)

echo "Checking if the command 'arp' is availiable ..."
rpm --quiet -q net-tools || sudo dnf install net-tools -y
##which arp >/dev/null 2>&1 || sudo dnf install net-tools -y 

echo Checking mac addresses that could already in use ...
arp -an > /tmp/.all_arp_entries 
INUSE=
> /tmp/.list_of_matching_arp_entries
for mac in $CP_MAC_ADDRESSES $WORKER_MAC_ADDRESSES
do
	#echo checking mac address: $mac ...
	if grep -q " $mac " /tmp/.all_arp_entries; then
		echo "Warning: Mac address $mac is already in use or has been in use."
		INUSE=1
		echo $mac >> /tmp/.list_of_matching_arp_entries
	fi
done

[ "$INUSE" ] && echo && echo "Consider changing 'mac_prefix' in $1.src/aba.conf and try again." && sleep 2 && echo 

echo Checking ip and mac addresses currently in use ...
> /tmp/.mac_list_filtered
if [ -s /tmp/.list_of_matching_arp_entries ]; then
	for mac in `cat /tmp/.list_of_matching_arp_entries`
	do
		grep $mac /tmp/.all_arp_entries >> /tmp/.mac_list_filtered
	done

	ips=$(cat /tmp/.mac_list_filtered | cut -d\( -f2 | cut -d\) -f1)

	if [ "$ips" ]; then
		# Delete arp cache and refresh IPs with ping...
		echo "$ips" | xargs -L1 sudo arp -d
		for ip in $ips
		do
			ping -c1 $ip >/dev/null 2>&1 &
		done
		wait 
		sleep 2

		arp -an > /tmp/.all_arp_entries 
		P=
		INUSE=
		for mac in $CP_MAC_ADDRESSES $WORKER_MAC_ADDRESSES
		do
			#echo checking $mac ...
			if grep -q " $mac " /tmp/.all_arp_entries; then
				P="$P $mac"
				INUSE=1
			fi
		done
		[ "$INUSE" ] && echo -e "WARNING: One or more mac addresses currently in use ($P).\nConsider Changing 'mac_prefix' in $1.src/aba.conf and try again." && \
				echo "If you're running multiple OCP clusters, ensure no mac/ip addresses overlap!" && exit 1
	fi
fi

# Read in the cpu and mem values 
[ -s $1.src/aba.conf ] && source $1.src/aba.conf || exit 1

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

	echo "Create master: $name VM with ${CP_MAC_ADDRESSES_ARRAY[$a]} [$ISO_DATASTORE] images/agent-${CLUSTER_NAME}.iso $FOLDER/${CLUSTER_NAME}-$name"
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

	echo "Create and attach disk on [$GOVC_DATASTORE]"
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

	echo "Create worker: $name VM with ${WORKER_MAC_ADDRESSES_ARRAY[$a]} [$ISO_DATASTORE] images/agent-${CLUSTER_NAME}.iso $FOLDER/${CLUSTER_NAME}-$name"
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

	echo "Create and attach disk on [$GOVC_DATASTORE]"
	govc vm.disk.create \
		-vm ${CLUSTER_NAME}-$name \
		-name ${CLUSTER_NAME}-$name/${CLUSTER_NAME}-$name \
		-size 120GB \
		-thick=false \
		-ds=$GOVC_DATASTORE
	let i=$i+1
done

