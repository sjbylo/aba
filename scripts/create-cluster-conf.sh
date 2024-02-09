#!/usr/bin/bash 
# Script to set up the cluster.conf file

source scripts/include_all.sh

source <(normalize-aba-conf)

if [ ! "$ocp_version" ]; then
	echo "Please run ./aba first!"
	exit 1
fi

if [ "$1" ]; then
	cd $1 || exit 1
	scripts/j2 templates/cluster-$1.conf > cluster.conf 
else
	scripts/j2 templates/cluster.conf > cluster.conf 
	$editor cluster.conf
fi

exit 0

