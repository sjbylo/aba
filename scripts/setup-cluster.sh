#!/bin/bash -e

source scripts/include_all.sh

#[ "$1" ] && set -x

source <(normalize-aba-conf)   # Fetch the domain name

name=standard
type=standard
[ "$1" ] && name=$1 && shift
[ "$1" ] && type=$1 && shift
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

echo "Creating '$name/cluster.conf' file for cluster type [$type]."
scripts/create-cluster-conf.sh $name $type

ask "Trigger the cluster with 'make $target'?" || exit 1
make $target

#echo 
#echo "Now, cd into the directory '$name' and run 'make'.  Example: cd $name && make"
#echo

