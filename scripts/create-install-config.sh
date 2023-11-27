#!/bin/bash 
# Script to generate the install-config.yaml 

#[ ! "$1" ] && echo Usage: `basename $0` --dir directory && exit 1
#[ "$DEBUG_ABA" ] && set -x

source aba.conf
source mirror.conf

echo Checking if dig is installed ...
which dig 2>/dev/null >&2 || sudo dnf install bind-utils -y

# Set the rendezvous_ip to the the first master's ip
export machine_ip_prefix=$(echo $machine_network | cut -d\. -f1-3).
export rendezvous_ip=$machine_ip_prefix$starting_ip_index

#SNO=
#[ $num_masters -eq 1 -a $num_workers -eq 0 ] && SNO=1 && echo Configuring for SNO ...

echo Validating the cluster configuraiton ...

set -x

export pull_secret=
export ssh_key_pub=
export additional_trust_bundle=
export image_content_sources=

pull_secret_mirror_file=../deps/pull-secret-mirror.json  

# Generate the needed agent-based config files ...

# Read in the needed files ...
echo Looking for registry pull secret ...
if [ -s $pull_secret_mirror_file ]; then
	export pull_secret=$(cat $pull_secret_mirror_file) 
else
	echo WARNING: No pull secret file found in $pull_secret_mirror_file.  Trying to use ~/.pull-secret.json.
	if [ -s ~/.pull-secret.json ]; then
		export pull_secret=$(cat ~/.pull-secret.json) 
	else
		echo "Error: No pull secrets found!!"
		exit 1
	fi
fi

[ -s $additional_trust_bundle_file ] && \
	export additional_trust_bundle=$(cat $additional_trust_bundle_file) || \
		echo WARNING: No file $additional_trust_bundle_file

[ -s $image_content_sources_file ] && \
	export image_content_sources=$(cat $image_content_sources_file) || \
		echo WARNING: No file $image_content_sources_file ...

[ -s $ssh_key_file ] && \
	export ssh_key_pub=$(cat $ssh_key_file) || \
		echo WARNING: No file $ssh_key_file ...

echo Generating Agent-based configuration file: $PWD/install-config.yaml 
j2 templates/install-config.yaml.j2 > install-config.yaml 


