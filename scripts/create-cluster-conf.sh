#!/usr/bin/bash 
# Script to set up the cluster.conf file

source scripts/include_all.sh

source <(normalize-aba-conf)

if [ ! "$ocp_version" ]; then
	echo "Please run ./aba first!"

	exit 1
fi

# jinja2 module is needed
scripts/install-rpms.sh internal

name=standard
type=standard
[ "$1" ] && name=$1 && shift
[ "$1" ] && type=$1


if [ ! -s cluster.conf ]; then
	if [ "$type" = "sno" ]; then
		export cluster_name=$name
		export api_vip=not-required
		export ingress_vip=not-required
		export starting_ip=$sno_starting_ip
		export mac_prefix=00:50:56:0x:xx:
		export num_masters=1
		export num_workers=0
	elif [ "$type" = "compact" ]; then
		export cluster_name=$name
		export api_vip=$compact_api_vip
		export ingress_vip=$compact_ingress_vip
		export starting_ip=$compact_starting_ip
		export mac_prefix=00:50:56:1x:xx:
		export num_masters=3
		export num_workers=0
	else # 'name=mycluster'
		export cluster_name=$name
		export api_vip=$standard_api_vip
		export ingress_vip=$standard_ingress_vip
		export starting_ip=$standard_starting_ip
		export mac_prefix=00:50:56:2x:xx:
		export num_masters=3
		export num_workers=3
	fi

	scripts/j2 templates/cluster.conf > cluster.conf 

	# For sno, ensure these values are commented out as they are not needed!
	[ "$type" = "sno" ] && sed -i -e "s/^api_vip=/#api_vip=/g" -e "s/^ingress_vip=/#ingress_vip=/g" cluster.conf

	if [ "$ask" ]; then
		edit_file cluster.conf "Edit the cluster.conf file to set all the parameters for OpenShift"
	fi
fi

exit 0

