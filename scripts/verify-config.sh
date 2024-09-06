#!/bin/bash 
# Script to do some simple verification of install-config.yaml

source scripts/include_all.sh

source <(normalize-aba-conf)
source <(normalize-cluster-conf)
source <(normalize-mirror-conf)

# Set the rendezvous_ip to the the first master's ip
export machine_ip_prefix=$(echo $machine_network | cut -d\. -f1-3).
export rendezvous_ip=$machine_ip_prefix$starting_ip

SNO=
[ $num_masters -eq 1 -a $num_workers -eq 0 ] && SNO=1 && echo "Configuration is for Single Node Openshift (SNO) ..."

[ $num_masters -ne 1 -a $num_masters -ne 3 ] && echo_red "Error: number of masters can only be '1' or '3'" && exit 1
echo "Master count is valid [$num_masters]"

# Checking for invalid config 
if [ $num_masters -eq 1 -a $num_workers -ne 0 ]; then
	echo_red "Error: number of workers must be '0' if number of masters is '1' (SNO)"
	exit 1
fi

echo "Master [$num_masters] and worker counts [$num_workers] are valid."

# If not SNO, then ensure api_vip and ingress_vip are defined 
if [ ! "$SNO" ]; then
	[ ! "$api_vip" -o ! "$ingress_vip" ] && echo_red "Error: 'api_vip' and 'ingress_vip' must be defined for this configuration" && exit 1
	echo "'api_vip' and 'ingress_vip' are defined [$api_vip] [$ingress_vip]"
else
	[ "$api_vip" -o "$ingress_vip" ] && echo "Warning: No need for 'api_vip' and 'ingress_vip' values in SNO configuration, they will be ignored." 
fi

# Checking if dig is installed ...

ip_of_api=$(dig +time=8 +short api.$cluster_name.$base_domain)
ip_of_apps=$(dig +time=8 +short x.apps.$cluster_name.$base_domain)

# If NOT SNO...
if [ ! "$SNO" ]; then
	# Ensure api DNS exists and points to correct ip
	[ "$ip_of_api" != "$api_vip" ] && echo_red "Error: DNS record [api.$cluster_name.$base_domain] does not resolve to [$api_vip]" && exit 1
	echo "DNS record for OCP api (api.$cluster_name.$base_domain) is valid [$ip_of_api]"

	# Ensure apps DNS exists and points to correct ip
	[ "$ip_of_apps" != "$ingress_vip" ] && echo_red "Error: DNS record [\*.apps.$cluster_name.$base_domain] does not resolve to [$ingress_vip]" && exit 1
	echo "DNS record for apps ingress (*.apps.$cluster_name.$base_domain) is valid [$ip_of_apps]"
else
	# For SNO...
	# Check values are both pointing to "rendezvous_ip"
	# Ensure api DNS exists 
	[ "$ip_of_api" != "$rendezvous_ip" ] && \
		echo_red "Error: DNS record [api.$cluster_name.$base_domain] does not resolve to the rendezvous ip [$rendezvous_ip]" && exit 1
	echo "DNS record for OCP api (SNO) is valid [$ip_of_api]"

	# Ensure apps DNS exists 
	[ "$ip_of_apps" != "$rendezvous_ip" ] && \
		echo_red "Error: DNS record [\*.apps.$cluster_name.$base_domain] does not resolve to the rendezvous ip [$rendezvous_ip]" && exit 1
	echo "DNS record for apps ingress (SNO) is valid [$ip_of_apps]"
fi

exit 0

