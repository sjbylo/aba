#!/bin/bash 
# Script to generate the agent-config.yaml file

. scripts/include_all.sh


#[ ! "$1" ] && echo Usage: `basename $0` --dir directory && exit 1
[ "$1" ] && set -x 

source aba.conf
source mirror.conf

####
# Function to generate a random HEX digit
generate_random_hex() {
    printf "%x" $((RANDOM%16))
}

# Function to replace "#" with different random HEX digits
replace_hash_with_random_hex() {
    local input_string=$1
    local output_string=""

    for ((i=0; i<${#input_string}; i++)); do
        if [ "${input_string:i:1}" == "#" ]; then
            output_string+=$(generate_random_hex)
        else
            output_string+="${input_string:i:1}"
        fi
    done

    echo "$output_string"
}

# Replace any '#" chars with random hex values
mac_prefix=$(replace_hash_with_random_hex "$mac_prefix")
####

# Set the rendezvous_ip to the the first master's ip
export machine_ip_prefix=$(echo $machine_network | cut -d\. -f1-3).
export rendezvous_ip=$machine_ip_prefix$starting_ip_index

##echo Validating the cluster configuraiton ...

scripts/verify-config.sh || exit 1

# Use j2cli to render the templates
echo Generating Agent-based configuration file: $PWD/agent-config.yaml 
scripts/j2 templates/agent-config.yaml.j2 > agent-config.yaml

echo
