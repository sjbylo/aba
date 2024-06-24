#!/bin/bash 
# Chekc if mac addresses are already in use and warn if they are

source scripts/include_all.sh

if [ ! "$CLUSTER_NAME" ]; then
	scripts/cluster-config-check.sh
	eval `scripts/cluster-config.sh || exit 1`
fi

CP_MAC_ADDRESSES_ARRAY=($CP_MAC_ADDRESSES)
WKR_MAC_ADDRESSES_ARRAY=($WKR_MAC_ADDRESSES)

# Need command 'arp' 

# if arp cannot be installed, then skip this script
which arp >/dev/null || exit 0

# Checking mac addresses that could already be in use (in arp cache) ...
arp -an > /tmp/.all_arp_entries 
IN_ARP_CACHE=
> /tmp/.list_of_matching_arp_entries
for mac in $CP_MAC_ADDRESSES $WKR_MAC_ADDRESSES
do
	# checking mac address: $mac ...
	if grep -q " $mac " /tmp/.all_arp_entries; then
		echo "Warning: Mac address $mac might already be in use (found in system ARP cache)."
		IN_ARP_CACHE=1
		echo $mac >> /tmp/.list_of_matching_arp_entries
	fi
done

# Checking ip and mac addresses *currently* in use by clearing the cache ...
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
		MAC_IN_USE=
		for mac in $CP_MAC_ADDRESSES $WKR_MAC_ADDRESSES
		do
			# checking $mac ...
			if grep -q " $mac " /tmp/.all_arp_entries; then
				P="$P $mac"
				MAC_IN_USE=1
			fi
		done
		if [ "$MAC_IN_USE" ]; then
			[ "$TERM" ] && tput setaf 1
			echo "ERROR: One or more mac addresses are *currently* in use:$P" 
			echo "       Consider Changing 'mac_prefix' in cluster.conf and try again." 
			echo "       If you're running multiple OCP clusters, ensure no mac/ip addresses overlap!" 
			[ "$TERM" ] && tput sgr0

			exit 1
		fi
	fi
fi

if [ "$IN_ARP_CACHE" ]; then
	echo "Warning: Mac address conflics may cause the OCP installation to fail!" 
	echo "         Consider changing 'mac_prefix' in cluster.conf and try again."
	echo "         After clearing the ARP cache & pinging IPs, no more mac address conflics detected!"
fi

echo

exit 0

