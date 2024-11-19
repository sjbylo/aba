#!/bin/bash 
# Script to do some simple verification of install-config.yaml

source scripts/include_all.sh

source <(normalize-aba-conf)
source <(normalize-cluster-conf)
source <(normalize-mirror-conf)

[ ! "$cluster_name" ] && echo_red "Error: missing cluster_name value in cluster.conf!" >&2 && exit 1
[ ! "$base_domain" ] && echo_red "Error: missing base_domain value in cluster.conf!" >&2 && exit 1
[ ! "$machine_ip_prefix" ] && echo_red "Error: missing machine_ip_prefix value in cluster.conf!" >&2 && exit 1
[ ! "$starting_ip" ] && echo_red "Error: missing starting_ip value in cluster.conf!" >&2 && exit 1
[ ! "$num_masters" ] && echo_red "Error: missing num_masters value in cluster.conf!" >&2 && exit 1
[ ! "$num_workers" ] && echo_red "Error: missing num_workers value in cluster.conf!" >&2 && exit 1

cl_domain="$cluster_name.$base_domain"
cl_apps_domain="*.apps.$cl_domain"
cl_api_domain="api.$cl_domain"

# Set the rendezvous_ip to the first master's ip
export machine_ip_prefix=$(echo $machine_network | cut -d\. -f1-3).
export rendezvous_ip=$machine_ip_prefix$starting_ip

SNO=
[ $num_masters -eq 1 -a $num_workers -eq 0 ] && SNO=1 && echo_white "Configuration is for Single Node Openshift (SNO) ..."
[ $num_masters -ne 1 -a $num_masters -ne 3 ] && echo_red "Error: number of masters can only be 1 or 3!" >&2 && exit 1

echo_white "Master count: $num_masters is valid."

# Checking for invalid config 
if [ $num_masters -eq 1 -a $num_workers -ne 0 ]; then
	echo_red "Error: number of workers must be 0 if number of masters is 1 (SNO)!" >&2

	exit 1
fi

echo_white "Worker count: $num_workers is valid."

# If not SNO, then ensure api_vip and ingress_vip are defined 
if [ ! "$SNO" ]; then
	[ ! "$api_vip" -o ! "$ingress_vip" ] && \
		echo_red "Error: Values api_vip and ingress_vip must both be defined for this configuration!" >&2 && \
		exit 1

	echo_white "Values api_vip ($api_vip) and ingress_vip ($ingress_vip) are defined."
else
	[ "$api_vip" -o "$ingress_vip" ] && \
		echo_red "Warning: Values api_vip and ingress_vip are not required for SNO configuration, they will be ignored." >&2 
fi

ip_of_api=$(dig +time=8 +short $cl_api_domain)
ip_of_apps=$(dig +time=8 +short x.apps.$cl_domain)

[ ! "$ip_of_api" ] && ip_of_api="<empty>"
[ ! "$ip_of_apps" ] && ip_of_apps="<empty>"

# If NOT SNO...
if [ ! "$SNO" ]; then
	# Ensure api DNS exists and points to correct ip
	[ "$ip_of_api" != "$api_vip" ] && \
		echo_red "Error: DNS record $cl_api_domain does not resolve to $api_vip, it resolves to $ip_of_api!" >&2 && \
		exit 1

	echo_white "DNS record for OCP api ($cl_api_domain) is valid: $ip_of_api."

	# Ensure apps DNS exists and points to correct ip
	[ "$ip_of_apps" != "$ingress_vip" ] && \
		echo_red "Error: DNS record $cl_apps_domain does not resolve to $ingress_vip, it resolves to $ip_of_apps!" >&2 && \
		exit 1

	echo_white "DNS record for apps ingress ($cl_apps_domain) is valid: $ip_of_apps."
else
	# For SNO...
	# Check values are both pointing to "rendezvous_ip"
	# Ensure api DNS exists 
	[ "$ip_of_api" != "$rendezvous_ip" ] && \
		echo_red "Error: DNS record $cl_api_domain does not resolve to the rendezvous ip: $rendezvous_ip, it resolves to $ip_of_api!" >&2 && \
		exit 1

	echo_white "DNS record for OCP api ($cl_api_domain) is valid: $ip_of_api"

	# Ensure apps DNS exists 
	[ "$ip_of_apps" != "$rendezvous_ip" ] && \
		echo_red "Error: DNS record $cl_apps_domain does not resolve to the rendezvous ip: $rendezvous_ip, it resolves to $ip_of_apps!" >&2 && \
		exit 1

	echo_white "DNS record for apps ingress ($cl_apps_domain) is valid: $ip_of_apps"
fi

echo_green "Cluster configuration is valid."

exit 0

