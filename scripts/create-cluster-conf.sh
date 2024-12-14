#!/usr/bin/bash 
# Script to set up the cluster.conf file

source scripts/include_all.sh

source <(normalize-aba-conf)
source ../shortcuts.conf

if [ ! "$ocp_version" ]; then
	echo "Please run aba first or see the README.md file!"

	exit 1
fi

# jinja2 module is needed
scripts/install-rpms.sh internal

[ -s cluster.conf ] && exit 0

name=standard
type=standard
[ "$1" ] && name=$1 && shift
[ "$1" ] && type=$1

# Override type from shortcuts?
[ "${shortcuts["$name:type"]}" ] && export type=${shortcuts["$name:type"]}

if [ "$DEBUG_ABA" ]; then
	echo_cyan "Creating cluster directory for [$name] of type [$type]"
fi

# Set defaults 
export mac_prefix=00:50:56:2x:xx:
export num_masters=3
export num_workers=3
export starting_ip="<add>"
export port0=ens160
export port1=ens192
export master_cpu_count=8
export master_mem=16
export worker_cpu_count=4
export worker_mem=8

# Now, need to create cluster.conf
export cluster_name=$name

# Set any shortcuts, but only if they exist, otherwise use the above default value
[ "${shortcuts["$name:api_vip"]}" ]		&& export api_vip=${shortcuts["$name:api_vip"]}
[ "${shortcuts["$name:ingress_vip"]}" ]		&& export ingress_vip=${shortcuts["$name:ingress_vip"]}
[ "${shortcuts["$name:starting_ip"]}" ]		&& export starting_ip=${shortcuts["$name:starting_ip"]}
[ "${shortcuts["$name:num_masters"]}" ]		&& export num_masters=${shortcuts["$name:num_masters"]}
[ "${shortcuts["$name:num_workers"]}" ]		&& export num_workers=${shortcuts["$name:num_workers"]}
[ "${shortcuts["$name:mac_prefix"]}" ]		&& export mac_prefix=${shortcuts["$name:mac_prefix"]}
[ "${shortcuts["$name:master_cpu_count"]}" ]	&& export master_cpu_count=${shortcuts["$name:master_cpu_count"]}
[ "${shortcuts["$name:master_mem"]}" ]		&& export master_mem=${shortcuts["$name:master_mem"]}
[ "${shortcuts["$name:worker_cpu_count"]}" ]	&& export worker_cpu_count=${shortcuts["$name:worker_cpu_count"]}
[ "${shortcuts["$name:worker_mem"]}" ]		&& export worker_mem=${shortcuts["$name:worker_mem"]}
[ "${shortcuts["$name:port0"]}" ]		&& export port0=${shortcuts["$name:port0"]}
[ "${shortcuts["$name:port1"]}" ]		&& export port1=${shortcuts["$name:port1"]}

#[ ! "$api_vip" ] && export api_vip=not-required
#[ ! "$ingress_vip" ] && export ingress_vip=not-required

if [ "$type" = "sno" ]; then
	export num_masters=1
	export num_workers=0
	export mac_prefix=00:50:56:0x:xx:
elif [ "$type" = "compact" ]; then
	export num_masters=3
	export num_workers=0
	export mac_prefix=00:50:56:1x:xx:
fi

scripts/j2 templates/cluster.conf > cluster.conf 

# For sno, ensure these values are commented out as they are not needed!
[ "$type" = "sno" ] && sed -E -i -e "s/^api_vip=[^ \t]*/#api_vip=not-required/g" -e "s/^ingress_vip=[^ \t]*/#ingress_vip=not-required/g" cluster.conf

edit_file cluster.conf "Edit the cluster.conf file to set all the required parameters for OpenShift" || exit 1

exit 0

