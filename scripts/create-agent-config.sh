#!/bin/bash 
# Script to generate the agent-config.yaml file

#[ ! "$1" ] && echo Usage: `basename $0` --dir directory && exit 1
#[ "$DEBUG_ABA" ] && set -x

source aba.conf
source mirror.conf

# Set the rendezvous_ip to the the first master's ip
export machine_ip_prefix=$(echo $machine_network | cut -d\. -f1-3).
export rendezvous_ip=$machine_ip_prefix$starting_ip_index

echo Checking if dig is installed ...
which dig 2>/dev/null >&2 || sudo dnf install bind-utils -y

echo Validating the cluster configuraiton ...

scripts/verify-config.sh || exit 1

# Use j2cli to render the templates
echo Generating Agent-based configuration file: $PWD/agent-config.yaml 
j2 templates/agent-config.yaml.j2 > agent-config.yaml

