#!/bin/bash 
# Script to do some simple verification of install-config.yaml

. scripts/include_all.sh

source aba.conf
source mirror.conf

# Set the rendezvous_ip to the the first master's ip
export machine_ip_prefix=$(echo $machine_network | cut -d\. -f1-3).
export rendezvous_ip=$machine_ip_prefix$starting_ip_index

SNO=
[ $num_masters -eq 1 -a $num_workers -eq 0 ] && SNO=1 && echo "Configuration is for Single Node Openshift (SNO) ..."

echo Validating the cluster configuraiton ...

echo Checking master count is valid ...
[ $num_masters -ne 1 -a $num_masters -ne 3 ] && echo "Error: number of masters can only be '1' or '3'" && exit 1

echo Checking SNO config ...
[ "$SNO" -a $num_masters -eq 1 -a $num_workers -ne 0 ] && echo "Error: number of workers must be '0' if number of masters is '1 (SNO)" && exit 1

# If not SNO, then ensure api_vip and ingress_vip are defined 
echo Checking api_vip and ingress_vip are defined ...
if [ ! "$SNO" ]; then
	[ ! "$api_vip" -o ! "$ingress_vip" ] && echo "Error: 'api_vip' and 'ingress_vip' must be defined for this configuration" && exit 1
fi


ip_api=$(dig +short api.$cluster_name.$base_domain)
ip_apps=$(dig +short x.apps.$cluster_name.$base_domain)
	
# If NOT SNO...
if [ ! "$SNO" ]; then
	# Ensure api DNS exists 
	[ "$ip_api" != "$api_vip" ] && echo "WARNING: DNS record [api.$cluster_name.$base_domain] does not resolve to [$api_vip]" && exit 1

	# Ensure apps DNS exists 
	[ "$ip_apps" != "$ingress_vip" ] && echo "WARNING: DNS record [\*.apps.$cluster_name.$base_domain] does not resolve to [$ingress_vip]" && exit 1
else
	# Check values are pointing to "rendezvous_ip"
	# Ensure api DNS exists 
	[ "$ip_api" != "$rendezvous_ip" ] && \
		echo "WARNING: DNS record [api.$cluster_name.$base_domain] does not resolve to the rendezvous ip [$rendezvous_ip]" && exit 1

	# Ensure apps DNS exists 
	[ "$ip_apps" != "$rendezvous_ip" ] && \
		echo "WARNING: DNS record [\*.apps.$cluster_name.$base_domain] does not resolve to the rendezvous ip [$rendezvous_ip]" && exit 1
fi

### Ensure registry dns entry exists and points to the bastion's ip
##ip=$(dig +short $reg_host)
##ip_int=$(ip route get 1 | grep -oP 'src \K\S+')
##[ "$ip" != "$ip_int" ] && echo "WARNING: DNS record [$reg_host] does not resolve to the bastion ip [$ip_int]!" ### && exit 1

exit 0

