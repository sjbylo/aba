#!/bin/bash 
# Script to do some simple verification of install-config.yaml

source scripts/include_all.sh

source <(normalize-aba-conf)
source <(normalize-cluster-conf)
source <(normalize-mirror-conf)

verify-aba-conf || exit 1
verify-cluster-conf || exit 1
verify-mirror-conf || exit 1

[ ! "$cluster_name" ] && echo_red "Error: missing cluster_name value in cluster.conf!" >&2 && exit 1
[ ! "$base_domain" ] && echo_red "Error: missing base_domain value in cluster.conf!" >&2 && exit 1
[ ! "$starting_ip" ] && echo_red "Error: missing starting_ip value in cluster.conf!" >&2 && exit 1
[ ! "$num_masters" ] && echo_red "Error: missing num_masters value in cluster.conf!" >&2 && exit 1
[ ! "$num_workers" ] && echo_red "Error: missing num_workers value in cluster.conf!" >&2 && exit 1

cl_domain="$cluster_name.$base_domain"
cl_ingress_domain="*.apps.$cl_domain"
cl_api_domain="api.$cl_domain"

# Set the rendezvous_ip to the first master's ip
export rendezvous_ip=$starting_ip

# Checking for invalid config 

SNO=
[ $num_masters -eq 1 -a $num_workers -eq 0 ] && SNO=1 && echo_white "Configuration is for Single Node Openshift (SNO) ..."
[ $num_masters -ne 1 -a $num_masters -ne 3 ] && echo_red "Error: number of masters can only be 1 or 3!" >&2 && exit 1

[ "$INFO_ABA" ] && echo_white "Master count: $num_masters is valid."

if [ $num_masters -eq 1 -a $num_workers -ne 0 ]; then
	echo_red "Error: number of workers must be 0 if number of masters is 1 (SNO)!" >&2

	exit 1
fi

[ "$INFO_ABA" ] && echo_white "Worker count: $num_workers is valid."

actual_ip_of_api=$(dig +time=8 +short $cl_api_domain)
actual_ip_of_ingress=$(dig +time=8 +short x.apps.$cl_domain)

# If not SNO, then ensure api_vip and ingress_vip are defined 
if [ ! "$SNO" ]; then
	# If api_vip defined and an IP address
	if [ "$api_vip" ] && echo "$api_vip" | grep -q -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
		[ "$INFO_ABA" ] && echo_white "Value 'api_vip' ($api_vip) is defined."
	else
		if echo "$actual_ip_of_api" | grep -q -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
			# Add into cluster.conf
			###sed -E -i "s/^^#{,1}api_vip=[^ \t]*/api_vip=$actual_ip_of_api /g" cluster.conf
			replace-value-conf cluster.conf api_vip $actual_ip_of_api
			echo_red "Warning: adding in actual IP address ($actual_ip_of_api) into cluster.conf" >&2
			echo_red "         Please verify this is correct! If not, edit cluster.conf file and try again!" >&2
			api_vip=$actual_ip_of_api
		else
			[ "$INFO_ABA" ] && echo_red "Error: Value 'api_vip' must be defined for this cluster configuration!" >&2 && exit 1
		fi
	fi

	# If ingress_vip is defined and an IP address
	if [ "$ingress_vip" ] && echo "$ingress_vip" | grep -q -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
		[ "$INFO_ABA" ] && echo_white "Value 'ingress_vip' ($ingress_vip) is defined."
	else
		# If ingress_vip not defined or an IP address
		if echo "$actual_ip_of_ingress" | grep -q -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
			# Add into cluster.conf
			###sed -E -i "s/^^#{,1}ingress_vip=[^ \t]*/ingress_vip=$actual_ip_of_ingress /g" cluster.conf
			replace-value-conf cluster.conf ingress_vip $actual_ip_of_ingress
			echo_red "Warning: adding in actual IP address ($actual_ip_of_ingress) into cluster.conf" >&2
			echo_red "         Please verify this is correct! If not, edit cluster.conf file and try again!" >&2
			ingress_vip=$actual_ip_of_ingress
		else
			[ "$INFO_ABA" ] && echo_red "Error: Value 'ingress_vip' must be defined for this cluster configuration!" >&2 && exit 1
		fi
	fi
else
	[ "$api_vip" -o "$ingress_vip" ] && \
		[ "$INFO_ABA" ] && echo_red "Warning: Values 'api_vip' and 'ingress_vip' are not required for SNO configuration, they will be ignored." >&2 
fi

[ ! "$actual_ip_of_api" ] && actual_ip_of_api="<empty>"
[ ! "$actual_ip_of_ingress" ] && actual_ip_of_ingress="<empty>"

# If NOT SNO...
if [ ! "$SNO" ]; then
	# Ensure api DNS exists and points to correct ip
	[ "$actual_ip_of_api" != "$api_vip" ] && \
		echo_red "Error: DNS record $cl_api_domain does not resolve to $api_vip, it resolves to $actual_ip_of_api!" >&2 && \
		exit 1

	[ "$INFO_ABA" ] && echo_white "DNS record for OCP api ($cl_api_domain) exists: $actual_ip_of_api."

	# Ensure apps DNS exists and points to correct ip
	[ "$actual_ip_of_ingress" != "$ingress_vip" ] && \
		echo_red "Error: DNS record $cl_ingress_domain does not resolve to $ingress_vip, it resolves to $actual_ip_of_ingress!" >&2 && \
		exit 1

	[ "$INFO_ABA" ] && echo_white "DNS record for apps ingress ($cl_ingress_domain) exists: $actual_ip_of_ingress."
else
	# For SNO...
	# Check values are both pointing to "rendezvous_ip"
	# Ensure api DNS exists 
	[ "$actual_ip_of_api" != "$rendezvous_ip" ] && \
		echo_red "Error: DNS record $cl_api_domain does not resolve to the rendezvous ip: $rendezvous_ip, it resolves to $actual_ip_of_api!" >&2 && \
		exit 1

	[ "$INFO_ABA" ] && echo_white "DNS record for OCP api ($cl_api_domain) exists: $actual_ip_of_api"

	# Ensure apps DNS exists 
	[ "$actual_ip_of_ingress" != "$rendezvous_ip" ] && \
		echo_red "Error: DNS record $cl_ingress_domain does not resolve to the rendezvous ip: $rendezvous_ip, it resolves to $actual_ip_of_ingress!" >&2 && \
		exit 1

	[ "$INFO_ABA" ] && echo_white "DNS record for apps ingress ($cl_ingress_domain) exists: $actual_ip_of_ingress"
fi

echo_green "Cluster configuration is valid."

exit 0

