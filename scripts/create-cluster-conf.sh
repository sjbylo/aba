#!/usr/bin/bash 
# Script to set up the cluster.conf file

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

source <(normalize-aba-conf)

verify-aba-conf

if [ ! "$ocp_version" ]; then
	echo_red "Error: 'ocp_version' not set in aba/aba.conf.  Run aba in the root of Aba's repository or see the aba/README.md on how to get started."

	exit 1
fi

# jinja2 module is needed
scripts/install-rpms.sh internal

[ -s cluster.conf ] && exit 0

##declare -A shortcuts  # Need to declare just in case the shortcuts.conf file is not available
##[ -s ../shortcuts.conf ] && source ../shortcuts.conf  # Values can be set in this file for testing 

name=standard
type=standard

. <(process_args $*)

aba_debug "Creating cluster directory for [$name] of type [$type]"

# Network values are optional in aba.conf (e.g. bundle workflow) but mandatory
# for cluster.conf.  Auto-detect any missing values and write them into aba.conf,
# then abort so the user can review before proceeding.
_filled=0
if [ ! "$domain" ]; then
	v=$(get_domain) && [ "$v" ] && replace-value-conf -n domain -v "$v" -f aba.conf && domain="$v"
	[ "$domain" ] && { aba_info "Auto-detected domain=$domain"; _filled=$((_filled+1)); }
fi
if [ ! "$machine_network" ]; then
	v=$(get_machine_network) && [ "$v" ] && replace-value-conf -n machine_network -v "$v" -f aba.conf && machine_network="$v"
	[ "$machine_network" ] && { aba_info "Auto-detected machine_network=$machine_network"; _filled=$((_filled+1)); }
fi
if [ ! "$dns_servers" ]; then
	v=$(get_dns_servers) && [ "$v" ] && replace-value-conf -n dns_servers -v "$v" -f aba.conf && dns_servers="$v"
	[ "$dns_servers" ] && { aba_info "Auto-detected dns_servers=$dns_servers"; _filled=$((_filled+1)); }
fi
if [ ! "$next_hop_address" ]; then
	v=$(get_next_hop) && [ "$v" ] && replace-value-conf -n next_hop_address -v "$v" -f aba.conf && next_hop_address="$v"
	[ "$next_hop_address" ] && { aba_info "Auto-detected next_hop_address=$next_hop_address"; _filled=$((_filled+1)); }
fi
if [ ! "$ntp_servers" ]; then
	v=$(get_ntp_servers) && [ "$v" ] && replace-value-conf -n ntp_servers -v "$v" -f aba.conf && ntp_servers="$v"
	[ "$ntp_servers" ] && { aba_info "Auto-detected ntp_servers=$ntp_servers"; _filled=$((_filled+1)); }
fi
if [ $_filled -gt 0 ]; then
	aba_abort \
		"$_filled network value(s) were auto-detected and written to aba.conf." \
		"Please review aba.conf and re-run the command."
fi
# If auto-detection failed for any values, tell the user which ones
_missing=0
[ ! "$domain" ]			&& { echo_red "Error: 'domain' could not be detected. Set it in aba.conf." >&2; _missing=$((_missing+1)); }
[ ! "$machine_network" ]	&& { echo_red "Error: 'machine_network' could not be detected. Set it in aba.conf." >&2; _missing=$((_missing+1)); }
[ ! "$dns_servers" ]		&& { echo_red "Error: 'dns_servers' could not be detected. Set it in aba.conf." >&2; _missing=$((_missing+1)); }
[ ! "$next_hop_address" ]	&& { echo_red "Error: 'next_hop_address' could not be detected. Set it in aba.conf." >&2; _missing=$((_missing+1)); }
[ ! "$ntp_servers" ]		&& { echo_red "Error: 'ntp_servers' could not be detected. Set it in aba.conf." >&2; _missing=$((_missing+1)); }
[ $_missing -gt 0 ] && aba_abort "$_missing network value(s) could not be auto-detected. Set them in aba.conf."

# If not already set, set reasonable defaults
# Note: VMware mac address range for VMs is 00:50:56:00:00:00 to 00:50:56:3F:FF:FF 
[ ! "$starting_ip" ]		&& export starting_ip="ADD-IP-ADDR-HERE"
[ ! "$mac_prefix" ]		&& export mac_prefix=00:50:56:2x:xx:
[ ! "$num_masters" ]		&& export num_masters=3
[ ! "$num_workers" ]		&& export num_workers=3
[ ! "$ports" ]			&& export ports=ens160
[ ! "$port0" ]			&& export port0=ens160
[ ! "$port1" ]			&& export port1=
[ ! "$vlan" ]			&& export vlan=
[ ! "$master_cpu_count" ]	&& export master_cpu_count=8
[ ! "$master_mem" ]		&& export master_mem=16
[ ! "$worker_cpu_count" ]	&& export worker_cpu_count=4
[ ! "$worker_mem" ]		&& export worker_mem=8
[ ! "$int_connection" ]		&& export int_connection=
[ ! "$data_disk" ]		&& export data_disk=500

# Now, need to create cluster.conf
export cluster_name=$name

# Set reasonable defaults for sno and compact
if [ "$type" = "sno" ]; then
	export num_masters=1
	export num_workers=0
	export mac_prefix=00:50:56:0x:xx:
elif [ "$type" = "compact" ]; then
	export num_masters=3
	export num_workers=0
	export mac_prefix=00:50:56:1x:xx:
fi

# This takes quite a few exported vars as input
if ! scripts/j2 templates/cluster.conf.j2 > cluster.conf; then
	rm -f cluster.conf
	echo_red "Error: failed to render cluster.conf (is python3 installed?)."
	exit 1
fi

# For sno, ensure these values are commented out as they are not needed!
[ "$type" = "sno" ] && sed -E -i -e "s/^api_vip=[^ \t]*/#api_vip=not-required/g" -e "s/^ingress_vip=[^ \t]*/#ingress_vip=not-required/g" cluster.conf

edit_file cluster.conf "Edit the cluster.conf file to set all the required parameters for OpenShift installation" #### don't want error here, just stop || exit 1

exit 0

