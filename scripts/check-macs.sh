#!/bin/bash 

source scripts/include_all.sh

if [ ! "$CLUSTER_NAME" ]; then
	scripts/cluster-config-check.sh
	eval `scripts/cluster-config.sh || exit 1`
fi

CP_MAC_ADDRESSES_ARRAY=($CP_MAC_ADDRESSES)
WORKER_MAC_ADDRESSES_ARRAY=($WORKER_MAC_ADDRESSES)

# Need command 'arp' 


# if arp cannot be installed, then skip this script
which arp >/dev/null || exit 0

##echo Checking mac addresses that could already in use ...
arp -an > /tmp/.all_arp_entries 
INUSE=
> /tmp/.list_of_matching_arp_entries
for mac in $CP_MAC_ADDRESSES $WORKER_MAC_ADDRESSES
do
	##echo checking mac address: $mac ...
	if grep -q " $mac " /tmp/.all_arp_entries; then
		echo "Warning: Mac address $mac might already be in use."
		INUSE=1
		echo $mac >> /tmp/.list_of_matching_arp_entries
	fi
done

#[ "$INUSE" ] && echo && echo "Consider changing 'mac_prefix' in cluster.conf and try again." && sleep 2 && echo 

##echo Checking ip and mac addresses currently in use ...
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
		if [ "$INUSE" ]; then
			[ "$TERM" ] && tput setaf 1
			echo "WARNING: One or more mac addresses are currently in use:$P" 
			echo "         Consider Changing 'mac_prefix' in cluster.conf and try again." 
			echo "         If you're running multiple OCP clusters, ensure no mac/ip addresses overlap!" 
			[ "$TERM" ] && tput sgr0

			exit 1
		fi
	fi
fi

exit 0

