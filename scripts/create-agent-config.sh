#!/bin/bash 
# Script to generate the agent-config.yaml file.  macs.conf file can be used to hold a list of addresses.

source scripts/include_all.sh

[ "$1" ] && set -x 

source <(normalize-aba-conf)
source <(normalize-cluster-conf)
source <(normalize-mirror-conf)

verify-aba-conf || exit 1
verify-cluster-conf || exit 1
verify-mirror-conf || exit 1

##############
# Functions for manipulating IP addresses and CIDRs

# Function to convert an IP address to a numeric value
to_numeric() {
  local ip=$1
  local a b c d
  IFS='.' read -r a b c d <<< "$ip"
  echo $((a * 256 ** 3 + b * 256 ** 2 + c * 256 + d))
}

# Function to convert a numeric value back to an IP address
from_numeric() {
  local num=$1
  echo "$((num >> 24 & 255)).$((num >> 16 & 255)).$((num >> 8 & 255)).$((num & 255))"
}

# Function to calculate the first and last usable IPs in the CIDR range
calculate_cidr_range() {
  local cidr=$1
  local ip prefix
  IFS='/' read -r ip prefix <<< "$cidr"

  local ip_num=$(to_numeric "$ip")
  local mask=$((0xFFFFFFFF << (32 - prefix) & 0xFFFFFFFF))
  local network=$((ip_num & mask))
  local broadcast=$((network | ~mask & 0xFFFFFFFF))

  local first_usable=$((network + 1))
  local last_usable=$((broadcast - 1))

  echo "$first_usable $last_usable"
}

# Generate an array of IP addresses from a CIDR range
generate_ip_array() {
  local cidr=$1
  local start_ip=$2
  local count=$3

  # Calculate the CIDR range
  read -r first_usable last_usable <<< $(calculate_cidr_range "$cidr")

  # Convert the starting IP to a numeric value
  local current_ip=$(to_numeric "$start_ip")
  
  # Initialize IP array
  local -a ip_array=()

  for ((i = 0; i < count; i++)); do
    if ((current_ip > last_usable)); then
      echo "Reached the end of the CIDR range." >&2
      break
    fi
    ip_array+=("$(from_numeric "$current_ip")")
    ((current_ip++))
  done

  echo "${ip_array[@]}"
}

##############

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
#export machine_ip_prefix=$(echo $machine_network | cut -d\. -f1-3).
#export rendezvous_ip=$machine_ip_prefix$starting_ip
ip_cnt=$(expr $num_masters + $num_workers)
if ! echo $starting_ip | grep -q -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
	echo_red "Error: value 'starting_ip' [$starting_ip] is missing or invalid. Should be an IP address from within your machine CIDR." >&2 

	exit 1
fi

export rendezvous_ip=$starting_ip

# Generate list of ip addresses from the CIDR and starting ip address
export arr_ips=$(generate_ip_array "$machine_network/$prefix_length" "$starting_ip" "$ip_cnt")

# Create ports array
export arr_ports=$(echo $ports | tr "," " " | tr -s "[:space:]")

read -r -a arr <<< "$arr_ports"
num_ports=${#arr[@]}

#echo arr_ports=${arr_ports[@]}
#num_ports=$(echo "$arr_ports" | wc -l)
#echo num_ports=${#arr_ports[@]}
[ "$INFO_ABA" ] && echo_white "Ports=${arr_ports[@]} and num_ports=$num_ports"

# Generate the mac addresses or get them from 'macs.conf'
# Goal is to allow user to BYO mac addresses for bare-metal use-case. So, we generate the addresses in advance into an array "arr_". scripts/j2 will create a python list.
if [ -s macs.conf ]; then
	grep -E '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' macs.conf > .macs.conf
else
	# Since the jinja2 template now uses a simple list, we can also auto-generate the addresses in a similar way for VMs. 
	# Note, double the number of mac addresses are genrated in case port bonding is required (ports and vlan in cluster.conf)
	#for i in $(seq 1 `expr $num_masters \* $num_ports + $num_workers \* $num_ports`); do
	for i in $(seq 1 `expr \( $num_masters + $num_workers \) \* $num_ports`); do
		printf "%s%02d\n" $mac_prefix $i
	done > .macs.conf
fi
export arr_macs=$(cat .macs.conf | tr "\n" " " | tr -s "[:space:]")  # scripts/j2 converts arr env vars starting with "arr_" into a python list which jinja2 can work with.
rm -f .macs.conf

# Set up the dns server(s)
export arr_dns_servers=$(echo $dns_servers | tr -d "[:space:]" | tr "," " ")  # scripts/j2 converts arr env vars starting with "arr_" into a python list which jinja2 can work with.
[ "$INFO_ABA" ] && echo_cyan "Adding DNS server(s): $arr_dns_servers"

# Set up the ntp server(s)
export arr_ntp_servers=$(echo $ntp_servers | tr -d "[:space:]" | tr "," " ")  # scripts/j2 converts arr env vars starting with "arr_" into a python list which jinja2 can work with.
[ "$INFO_ABA" ] && echo_cyan "Adding NTP server(s): $arr_ntp_servers"

# Use j2cli to render the templates
if [ "$INFO_ABA" ]; then
	echo
	echo Generating Agent-based configuration file: $PWD/agent-config.yaml 
	echo
fi

if [ $num_ports -gt 1 ]; then
	if [ "$vlan" ]; then
		# Multiple ports and vlan defined
		template_file=agent-config-vlan-bond.yaml.j2
		[ "$INFO_ABA" ] && echo_white "Using vlan and bonding agent config template: templates/$template_file (ports=${arr_ports[@]} vlan=$vlan)"
	else
		# Multiple ports and no vlan
		template_file=agent-config-bond.yaml.j2
		[ "$INFO_ABA" ] && echo_white "Using access mode bonding agent config template: templates/$template_file (ports=${arr_ports[@]})"
	fi
elif [ "$vlan" ]; then
	# Only one port and vlan defined
	template_file=agent-config-vlan.yaml.j2
	[ "$INFO_ABA" ] && echo_white "Using vlan agent config template: templates/$template_file (ports=${arr_ports[@]} vlan=$vlan)"
else
	# Only one port no vlan defined
	template_file=agent-config.yaml.j2
	[ "$INFO_ABA" ] && echo_white "Using standard agent config template: templates/$template_file (ports=${arr_ports[@]})"
fi

# echo "arr_ips=${arr_ips[@]}"
# DEBUG # echo "arr_dns_servers=${arr_dns_servers[@]}"
# DEBUG # echo "arr_ntp_servers=${arr_ntp_servers[@]}"
# DEBUG # echo "arr_macs=${arr_macs[@]}"

# Note that arr_ports, arr_ips, arr_dns_servers, arr_ntp_servers, arr_macs, mac_prefix, rendezvous_ip and others are exported vars and used by scripts/j2 
[ -s agent-config.yaml ] && cp agent-config.yaml agent-config.yaml.backup
scripts/j2 templates/$template_file > agent-config.yaml

echo_green "$PWD/agent-config.yaml generated successfully!"
echo

