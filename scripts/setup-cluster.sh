#!/bin/bash -e
# Create the cluster build dir

source scripts/include_all.sh

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
	make -s init
else
	cd $name 
	make -s clean init
fi

echo_magenta "Creating '$name/cluster.conf' file for cluster type '$cluster_type'."
scripts/create-cluster-conf.sh $name $cluster_type

msg="Install the cluster with 'cd $name; aba'"
[ "$target" ] && msg="Make the target '$target' with 'cd $name; aba $target'"

# adding "exit 0" here to give best practise instuctions to cd into the cluster dir!
if [ "$ask" ]; then
	echo
	echo_cyan "The cluster directory has been created: $name"
	echo_cyan "$msg"
	echo

	exit 0
fi

make -s $target

#if ask $msg; then
#	make $target
#
#	echo 
#	[ "$target" ] && 
#	echo_cyan "To continue working on this cluster, change into the directory '$name'. Example: cd $name; aba $target"
#	echo
#else
#	echo 
#	echo_cyan "To continue working on this cluster, change into the directory '$name' and run 'aba'.  Example: cd $name; aba"
#	echo
#fi

