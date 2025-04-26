#!/bin/bash 
# Chekc if mac addresses are already in use and warn if they are

source scripts/include_all.sh

if [ ! "$CLUSTER_NAME" ]; then
	scripts/cluster-config-check.sh
	eval `scripts/cluster-config.sh || exit 1`
fi

CP_MAC_ADDR_ARRAY=($CP_MAC_ADDR)
WKR_MAC_ADDR_ARRAY=($WKR_MAC_ADDR)

# Need command 'arp' 

# if arp cannot be installed, then skip this script
which arp >/dev/null || exit 0

# Checking mac addresses that could already be in use (in arp cache) ...
#arp -an > $tmp_dir/.all_arp_entries 
all_arp_entries=$(arp -an)

IN_ARP_CACHE=
#> $tmp_dir/.list_of_matching_arp_entries
list_of_matching_arp_entries=
for mac in $CP_MAC_ADDR $WKR_MAC_ADDR
do
	# checking mac address: $mac ...
	#if grep -q " $mac " $tmp_dir/.all_arp_entries; then
	if echo "$all_arp_entries" | grep -q " $mac "; then
		echo "Warning: Mac address $mac might already be in use (found in system ARP cache)."
		IN_ARP_CACHE=1
		#echo $mac >> $tmp_dir/.list_of_matching_arp_entries
		# If the list is empty, add the mac address, else append the mac addr.
		[ "$list_of_matching_arp_entries" ] && list_of_matching_arp_entries="${$list_of_matching_arp_entries}"$'\n'"$mac" || list_of_matching_arp_entries=$mac
		# my_list="${my_list}"$'\n'"dragonfruit"
	fi
done

# Checking ip and mac addresses *currently* in use by clearing the cache ...
#> $tmp_dir/.mac_list_filtered
mac_list_filtered=
#if [ -s $tmp_dir/.list_of_matching_arp_entries ]; then
if [ "$list_of_matching_arp_entries" ]; then
	#for mac in `cat $tmp_dir/.list_of_matching_arp_entries`
	for mac in $list_of_matching_arp_entries
	do
		#grep $mac $tmp_dir/.mac_list_filtered
		echo "$mac_list_filtered" | grep $mac
	done

	#ips=$(cat $tmp_dir/.mac_list_filtered | cut -d\( -f2 | cut -d\) -f1)
	ips=$(echo "$mac_list_filtered" | cut -d\( -f2 | cut -d\) -f1)

	if [ "$ips" ]; then
		# Delete arp cache and refresh IPs with ping...
		echo "$ips" | xargs -L1 $SUDO arp -d
		for ip in $ips
		do
			ping -c1 $ip >/dev/null 2>&1 &
		done
		wait 
		sleep 2

		#arp -an > $tmp_dir/.all_arp_entries 
		all_arp_entries=$(arp -an)
		P=
		MAC_IN_USE=
		for mac in $CP_MAC_ADDR $WKR_MAC_ADDR
		do
			# checking $mac ...
			#if grep -q " $mac " $tmp_dir/.all_arp_entries; then
			if echo "$all_arp_entries" | grep -q " $mac "; then
				P="$P $mac"
				MAC_IN_USE=1
			fi
		done
		if [ "$MAC_IN_USE" ]; then
			echo_red "Error: One or more mac addresses are *currently* in use:$P" >&2 
			echo_red "       Consider Changing 'mac_prefix' in cluster.conf and try again." >&2 
			echo_red "       If you're running multiple OCP clusters, ensure no mac/ip addresses overlap!" >&2 

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

