#!/bin/bash 
# Script to generate the agent-config.yaml file.  macs.conf file can be used to hold a list of addresses.

source scripts/include_all.sh

[ "$1" ] && set -x 

source <(normalize-aba-conf)
source <(normalize-cluster-conf)
source <(normalize-mirror-conf)

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


# Set the rendezvous_ip to the the first master's ip
export machine_ip_prefix=$(echo $machine_network | cut -d\. -f1-3).
export rendezvous_ip=$machine_ip_prefix$starting_ip

scripts/verify-config.sh || exit 1

# Generate the mac addresses or get them from 'macs.conf'
# Goal is to allow user to BYO mac addresses for bare-metal use-case. So, we generate the addresses in advance into an array "arr_". scripts/j2 will create a python list.
if [ -s macs.conf ]; then
	grep -E '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' macs.conf > .macs.conf
else
	# Since the jinja2 template now uses a simple list, we can also auto-generate the addresses in a similar way for VMs. 
	# Note, double the number of mac addresses are genrated in case port bonding is required (port0/1 and vlan in cluster.conf)
	for i in $(seq 1 `expr $num_masters \* 2 + $num_workers \* 2`); do
		printf "%s%02d\n" $mac_prefix $i
	done > .macs.conf
fi
export arr_macs=$(cat .macs.conf | tr "\n" " " | tr -s "[:space:]")  # scripts/j2 converts arr env vars starting with "arr_" into a python list which jinja2 can work with.
rm -f .macs.conf

# Set up the dns server(s)
export arr_dns_servers=$(echo $dns_servers | tr -d "[:space:]" | tr "," " ")  # scripts/j2 converts arr env vars starting with "arr_" into a python list which jinja2 can work with.
echo_cyan "Adding DNS server(s): $arr_dns_servers"

# Use j2cli to render the templates
echo
echo Generating Agent-based configuration file: $PWD/agent-config.yaml 
echo

if [ "$port0" -a "$port1" -a "$vlan" ]; then
	template_file=agent-config-vlan-bond.yaml.j2
	echo_white "Using vlan and bonding agent config template '$template_file' (port0=$port0 port1=$port1 vlan=$vlan)"
elif [ "$port0" -a "$port1" -a ! "$vlan" ]; then
	template_file=agent-config-bond.yaml.j2
	echo_white "Using access mode bonding agent config template '$template_file' (port0=$port0 port1=$port1)"
elif [ "$port0" -a ! "$port1" -a "$vlan" ]; then
	template_file=agent-config-vlan.yaml.j2
	echo_white "Using vlan agent config template '$template_file' (port0=$port0 port1=$port1)"
else
	template_file=agent-config.yaml.j2
	echo_white "Using standard agent config template '$template_file'"
fi

# Note that machine_ip_prefix, mac_prefix, rendezvous_ip and others are exported vars and used by scripts/j2 
[ -s agent-config.yaml ] && cp agent-config.yaml agent-config.yaml.backup
scripts/j2 templates/$template_file > agent-config.yaml

echo_green "$PWD/agent-config.yaml generated successfully!"
echo

