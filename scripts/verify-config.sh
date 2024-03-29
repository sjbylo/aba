#!/bin/bash 
# Script to do some simple verification of install-config.yaml

source scripts/include_all.sh

source <(normalize-cluster-conf)
source <(normalize-aba-conf)
source <(normalize-mirror-conf)

# Set the rendezvous_ip to the the first master's ip
export machine_ip_prefix=$(echo $machine_network | cut -d\. -f1-3).
export rendezvous_ip=$machine_ip_prefix$starting_ip_index

SNO=
[ $num_masters -eq 1 -a $num_workers -eq 0 ] && SNO=1 && echo "Configuration is for Single Node Openshift (SNO) ..."

##echo Validating the cluster configuraiton ...

[ $num_masters -ne 1 -a $num_masters -ne 3 ] && echo "Error: number of masters can only be '1' or '3'" && exit 1
echo "Master count is valid [$num_masters]"

#echo Checking SNO config ...
if [ "$SNO" -a $num_masters -eq 1 -a $num_workers -ne 0 ]; then
	echo "Error: number of workers must be '0' if number of masters is '1 (SNO)"
	exit 1
else
	echo "SNO master and worker count is valid [$num_masters] [$num_workers]"
fi

# If not SNO, then ensure api_vip and ingress_vip are defined 
#echo Checking api_vip and ingress_vip are defined ...
if [ ! "$SNO" ]; then
	[ ! "$api_vip" -o ! "$ingress_vip" ] && echo "Error: 'api_vip' and 'ingress_vip' must be defined for this configuration" && exit 1
	echo "'api_vip' and 'ingress_vip' are defined [$api_vip] [$ingress_vip]"
else
	[ "$api_vip" -o "$ingress_vip" ] && echo "'api_vip' and 'ingress_vip' are defined. No need for SNO, they will be ignored." 
fi

# Checking if dig is installed ...

ip_api=$(dig +time=8 +short api.$cluster_name.$base_domain)
ip_apps=$(dig +time=8 +short x.apps.$cluster_name.$base_domain)
	
# If NOT SNO...
if [ ! "$SNO" ]; then
	# Ensure api DNS exists 
	[ "$ip_api" != "$api_vip" ] && echo "WARNING: DNS record [api.$cluster_name.$base_domain] does not resolve to [$api_vip]" && exit 1
	echo "DNS record for api is valid [$ip_api]"

	# Ensure apps DNS exists 
	[ "$ip_apps" != "$ingress_vip" ] && echo "WARNING: DNS record [\*.apps.$cluster_name.$base_domain] does not resolve to [$ingress_vip]" && exit 1
	echo "DNS record for ingress is valid [$ip_apps]"
else
	# Check values are pointing to "rendezvous_ip"
	# Ensure api DNS exists 
	[ "$ip_api" != "$rendezvous_ip" ] && \
		echo "WARNING: DNS record [api.$cluster_name.$base_domain] does not resolve to the rendezvous ip [$rendezvous_ip]" && exit 1
	echo "DNS record for api (SNO) is valid [$ip_api]"

	# Ensure apps DNS exists 
	[ "$ip_apps" != "$rendezvous_ip" ] && \
		echo "WARNING: DNS record [\*.apps.$cluster_name.$base_domain] does not resolve to the rendezvous ip [$rendezvous_ip]" && exit 1
	echo "DNS record for ingress (SNO) is valid [$ip_apps]"
fi

exit 0

