#!/bin/bash 
# Script to generate the agent-config.yaml file

. scripts/include_all.sh

#[ ! "$1" ] && echo Usage: `basename $0` --dir directory && exit 1
[ "$1" ] && set -x 

source aba.conf
source mirror.conf

# Set the rendezvous_ip to the the first master's ip
export machine_ip_prefix=$(echo $machine_network | cut -d\. -f1-3).
export rendezvous_ip=$machine_ip_prefix$starting_ip_index

##echo Validating the cluster configuraiton ...

scripts/verify-config.sh || exit 1

# Use j2cli to render the templates
echo Generating Agent-based configuration file: $PWD/agent-config.yaml 
j2 templates/agent-config.yaml.j2 > agent-config.yaml

