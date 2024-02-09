#!/bin/bash -e

source scripts/include_all.sh

[ "$1" ] && set -x

source <(normalize-aba-conf)   # Fetch the domain name

mkdir $1   # If dir exists, exit
ln -fs ../templates/Makefile $1/Makefile
scripts/j2 templates/cluster-standard.conf > $1/cluster.conf
echo -n "Edit the config file $1/cluster.conf, hit RETURN "
read yn
$editor $1/cluster.conf
make -C $1

