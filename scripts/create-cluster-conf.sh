#!/usr/bin/bash 
# Script to set up the cluster.conf file

source scripts/include_all.sh

source <(normalize-aba-conf)

if [ ! "$ocp_version" ]; then
	echo "Please run ./aba first!"

	exit 1
fi

if [ "$1" ]; then
	# Expect the dir to exist, otherwise error out
	mkdir -p $1
	cd $1 
	ln -fs ../templates/Makefile 
	make init

	if [ "$1" = "sno" ]; then
		export cluster_name=$1
		export api_vip=not-required
		export ingress_vip=not-required
		export starting_ip=101
		export mac_prefix=00:50:56:0x:xx:
		export num_masters=1
		export num_workers=0
	elif [ "$1" = "compact" ]; then
		export cluster_name=$1
		export api_vip=$compact_api_vip
		export ingress_vip=$compact_ingress_vip
		export starting_ip=$compact_starting_ip
		export mac_prefix=00:50:56:1x:xx:
		export num_masters=3
		export num_workers=0
	# else, if 'standard' or 'name=mycluster'
	else
		export cluster_name=$1
		export api_vip=$standard_api_vip
		export ingress_vip=$standard_ingress_vip
		export starting_ip=$standard_starting_ip
		export mac_prefix=00:50:56:2x:xx:
		export num_masters=3
		export num_workers=2
	fi
			
	###scripts/j2 templates/cluster-$1.conf > cluster.conf 
	scripts/j2 templates/cluster.conf > cluster.conf 
	##[ "$1" = "sno" ] && sed -i -e "/^api_vip=.*$/d" -e "/^ingress_vip=.*$/d" cluster.conf
	[ "$1" = "sno" ] && sed -i -e "s/^api_vip=/#api_vip=/g" -e "s/^ingress_vip=/#ingress_vip=/g" cluster.conf

	$editor cluster.conf
#else
	#export cluster_name=$1
##	###export prefix_length is from aba.conf
	#export api_vip=$standard_api_vip
	#export ingress_vip=$standard_ingress_vip
	#export starting_ip=$standard_starting_ip
	#export mac_prefix=00:50:56:0x:xx:
	#export num_masters=3
	#export num_workers=2
#
	#scripts/j2 templates/cluster.conf > cluster.conf 
	#$editor cluster.conf
fi

exit 0

