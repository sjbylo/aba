#!/usr/bin/bash 
# Script to set up the cluster.conf file

source scripts/include_all.sh

source <(normalize-aba-conf)

verify-aba-conf # || exit 1

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
scripts/j2 templates/cluster.conf.j2 > cluster.conf 

# For sno, ensure these values are commented out as they are not needed!
[ "$type" = "sno" ] && sed -E -i -e "s/^api_vip=[^ \t]*/#api_vip=not-required/g" -e "s/^ingress_vip=[^ \t]*/#ingress_vip=not-required/g" cluster.conf

edit_file cluster.conf "Edit the cluster.conf file to set all the required parameters for OpenShift installation" #### don't want error here, just stop || exit 1

exit 0

