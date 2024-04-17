#!/bin/bash -e

source scripts/include_all.sh

#[ "$1" ] && set -x

source <(normalize-aba-conf)   # Fetch the domain name

name=standard
cluster_type=standard
[ "$1" ] && name=$1 && shift
[ "$1" ] && cluster_type=$1 && shift
[ "$1" ] && target=$1

if [ ! -d $name ]; then
	mkdir $name
	cd $name
	ln -fs ../templates/Makefile 
	make init
else
	cd $name 
	make clean init
fi

pwd
#make cluster.conf name=$name

echo "Creating '$name/cluster.conf' file for cluster type [$cluster_type]."
scripts/create-cluster-conf.sh $name $cluster_type

msg="Install the cluster with 'cd $name; make'?"
[ "$target" ] && msg="Trigger the cluster with 'cd $name; make $target'?"

if ask $msg; then
	make $target

	echo 
	[ "$target" ] && echo "If you want to continue working on this cluster, change into the directory '$name'. Example: 'cd $name && make help'"
	echo
else
	echo 
	echo "If you want to continue working on this cluster, change into the directory '$name' and run 'make'.  Example: 'cd $name && make' or 'cd $name && make help'"
	echo
fi

