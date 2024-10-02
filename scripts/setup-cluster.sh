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

echo_magenta "Creating '$name/cluster.conf' file for cluster type '$cluster_type'."
scripts/create-cluster-conf.sh $name $cluster_type

msg="Install the cluster with 'cd $name; make'"
[ "$target" ] && msg="Make the target '$target' with 'cd $name; make $target'"

# adding "exit 0" here to give best practise instuctions to cd into the cluster dir!
if [ "$ask" ]; then
	echo
	echo_cyan The cluster directory has been created: $name
	echo_cyan $msg
	echo

	exit 0
fi

if ask $msg; then
	make $target

	echo 
	[ "$target" ] && echo_cyan "To continue working on this cluster, change into the directory '$name'. Example: cd $name; make $target"
	echo
else
	echo 
	echo_cyan "To continue working on this cluster, change into the directory '$name' and run 'make'.  Example: cd $name; make"
	echo
fi

