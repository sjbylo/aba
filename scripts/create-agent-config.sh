#!/bin/bash 
# Script to generate the agent-config.yaml file

source scripts/include_all.sh


#[ ! "$1" ] && echo Usage: `basename $0` --dir directory && exit 1
[ "$1" ] && set -x 

source <(normalize-cluster-conf)
source <(normalize-aba-conf)
source <(normalize-mirror-conf)

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
        if [ "${input_string:i:1}" == "x" ]; then
            output_string+=$(generate_random_hex)
        else
            output_string+="${input_string:i:1}"
        fi
    done

    echo "$output_string"
}

# Replace any 'x" chars with random hex values
mac_prefix=$(replace_hash_with_random_hex "$mac_prefix")
####

# Set the rendezvous_ip to the the first master's ip
export machine_ip_prefix=$(echo $machine_network | cut -d\. -f1-3).
export rendezvous_ip=$machine_ip_prefix$starting_ip_index

scripts/verify-config.sh || exit 1

# Use j2cli to render the templates
echo
echo Generating Agent-based configuration file: $PWD/agent-config.yaml 
echo
# Note that machine_ip_prefix, mac_prefix, rendezvous_ip and others are exported vars and used by scripts/j2 
[ -s agent-config.yaml ] && cp agent-config.yaml agent-config.yaml.backup
scripts/j2 templates/agent-config.yaml.j2 > agent-config.yaml

echo "agent-config.yaml generated successfully"
