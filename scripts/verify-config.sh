#!/bin/bash 
# Script to do some simple verification of install-config.yaml

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

source <(normalize-aba-conf)
source <(normalize-cluster-conf)
source <(normalize-mirror-conf)

verify-aba-conf || exit 1
verify-cluster-conf || exit 1
verify-mirror-conf || exit 1

# These checks are actually also made in 'verify-cluster-conf'
[ ! "$cluster_name" ] && aba_abort "missing cluster_name value in cluster.conf!"
[ ! "$base_domain" ] && aba_abort "missing base_domain value in cluster.conf!"
[ ! "$starting_ip" ] && aba_abort "missing starting_ip value in cluster.conf!"
[ ! "$num_masters" ] && aba_abort "missing num_masters value in cluster.conf!"
[ ! "$num_workers" ] && aba_abort "missing num_workers value in cluster.conf!"

cl_domain="$cluster_name.$base_domain"
cl_ingress_domain="*.apps.$cl_domain"
cl_api_domain="api.$cl_domain"

# Set the rendezvous_ip to the first master's ip
export rendezvous_ip=$starting_ip

# Checking for invalid config 

SNO=
[ $num_masters -eq 1 -a $num_workers -eq 0 ] && SNO=1 && aba_info "Configuration is for Single Node Openshift (SNO) ..."
[ $num_masters -ne 1 -a $num_masters -ne 3 ] && aba_abort "number of masters can only be 1 or 3!"

aba_info "Master count: $num_masters is valid"

if [ $num_masters -eq 1 -a $num_workers -ne 0 ]; then
	aba_abort "number of workers must be 0 if number of masters is 1 (SNO)!"
fi

aba_info "Worker count: $num_workers is valid"

actual_ip_of_api=$(dig +time=8 +short $cl_api_domain)
actual_ip_of_ingress=$(dig +time=8 +short $RANDOM.apps.$cl_domain)   # Use $RANDOM to avoid DNS cache issue

# If not SNO, then ensure api_vip and ingress_vip are defined 
if [ ! "$SNO" ]; then
	# If api_vip defined and an IP address
	if [ "$api_vip" ] && echo "$api_vip" | grep -q -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
		aba_info "API endpoint: api_vip=$api_vip is defined"
	else
		if [ ! "$actual_ip_of_api" ]; then
			aba_abort "Missing DNS record $cl_api_domain" 
		elif echo "$actual_ip_of_api" | grep -q -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
			# Add into cluster.conf
			aba_warning -p Attention \
				"inserting actual IP address ($actual_ip_of_api) into cluster.conf" \
				"Please verify this is correct! If not, edit cluster.conf file and try again!" 
			replace-value-conf -n api_vip -v $actual_ip_of_api cluster.conf
			sleep 1
			api_vip=$actual_ip_of_api
		else
			aba_abort "Ingress endpoiont: api_vip must be defined for this cluster configuration!" 
		fi
	fi

	# If ingress_vip is defined and an IP address
	if [ "$ingress_vip" ] && echo "$ingress_vip" | grep -q -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
		aba_info "Ingress endpoiont: ingress_vip=$ingress_vip is defined"
	else
		# If ingress_vip not defined or an IP address
		if [ ! "$actual_ip_of_ingress" ]; then
			aba_abort "Missing DNS record $cl_ingress_domain!" 
		elif echo "$actual_ip_of_ingress" | grep -q -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
			# Add into cluster.conf
			aba_warning -p Attention \
				"inserting actual IP address ($actual_ip_of_ingress) into cluster.conf" \
				"Please verify this is correct! If not, edit cluster.conf file and try again!"
			replace-value-conf -n ingress_vip -v $actual_ip_of_ingress cluster.conf
			sleep 1
			ingress_vip=$actual_ip_of_ingress
		else
			aba_abort "Ingress endpoint: ingress_vip must be defined for this cluster configuration!"
		fi
	fi
else
	[ "$api_vip" -o "$ingress_vip" ] && \
		aba_warning "Cluster endpoints: api_vip and ingress_vip are not required for single-node (SNO) configuration, they will be ignored."
fi

[ ! "$actual_ip_of_api" ] && actual_ip_of_api="<empty>"
[ ! "$actual_ip_of_ingress" ] && actual_ip_of_ingress="<empty>"

# If NOT SNO...
if [ ! "$SNO" ]; then
	# Ensure api DNS exists and points to correct ip
	[ "$actual_ip_of_api" != "$api_vip" ] && \
		aba_abort "DNS record: $cl_api_domain does not resolve to $api_vip, it resolves to $actual_ip_of_api!"

	aba_info "DNS record for OpenShift api ($cl_api_domain) exists: $actual_ip_of_api"

	# Ensure apps DNS exists and points to correct ip
	[ "$actual_ip_of_ingress" != "$ingress_vip" ] && \
		aba_abort "DNS record: $cl_ingress_domain does not resolve to $ingress_vip, it resolves to $actual_ip_of_ingress!"

	aba_info "DNS record for apps ingress ($cl_ingress_domain) exists: $actual_ip_of_ingress"
else
	# For SNO...
	# Check values are both pointing to "rendezvous_ip"
	# Ensure api DNS exists 
	[ "$actual_ip_of_api" != "$rendezvous_ip" ] && \
		aba_abort "DNS record $cl_api_domain does not resolve to the rendezvous ip: $rendezvous_ip, it resolves to $actual_ip_of_api!"

	aba_info "DNS record for OpenShift api ($cl_api_domain) exists: $actual_ip_of_api"

	# Ensure apps DNS exists 
	[ "$actual_ip_of_ingress" != "$rendezvous_ip" ] && \
		aba_abort "DNS record $cl_ingress_domain does not resolve to the rendezvous ip: $rendezvous_ip, it resolves to $actual_ip_of_ingress!"

	aba_info "DNS record for apps ingress ($cl_ingress_domain) exists: $actual_ip_of_ingress"
fi

aba_info_ok "Cluster configuration is valid"

exit 0

