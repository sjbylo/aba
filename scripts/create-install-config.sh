#!/bin/bash 
# Script to generate the install-config.yaml 

. scripts/include_all.sh

#[ ! "$1" ] && echo Usage: `basename $0` --dir directory && exit 1
[ "$1" ] && set -x

source aba.conf
source mirror.conf

scripts/verify-release-image.sh

echo Checking if nmstate and skopeo are installed ...
inst=
rpm --quiet -q bind-utils 	|| inst="$inst bind-utils"
rpm --quiet -q nmstate	 	|| inst="$inst nmstate"
[ "$inst" ] && sudo dnf install $inst -y >/dev/null

# Set the rendezvous_ip to the the first master's ip
export machine_ip_prefix=$(echo $machine_network | cut -d\. -f1-3).
export rendezvous_ip=$machine_ip_prefix$starting_ip_index

#SNO=
#[ $num_masters -eq 1 -a $num_workers -eq 0 ] && SNO=1 && echo Configuring for SNO ...

echo Validating the cluster configuraiton ...

export pull_secret=
export ssh_key_pub=
export additional_trust_bundle=
export image_content_sources=

pull_secret_mirror_file=../deps/pull-secret-mirror.json  

# Generate the needed iso-agent-based config files ...

# Read in the needed files ...
echo Looking for mirror registry pull secret file ...
if [ -s $pull_secret_mirror_file ]; then
	export pull_secret=$(cat $pull_secret_mirror_file) 
	echo Found mirror registry pull secret file at $pull_secret_mirror_file
else
	echo WARNING: No mirror registry pull secret file found at $pull_secret_mirror_file.  Trying to use ./pull-secret.json.
	if [ -s ./pull-secret.json ]; then
		export pull_secret=$(cat ./pull-secret.json) 
		echo Found pull secret file at $PWD/pull-secret.json
	else
		echo "Error: No pull secrets found!!"
		exit 1
	fi
fi

# FIXME this should be simpler
ln -fs ../mirror/deps 
[ -s deps/$additional_trust_bundle_file ] && \
	export additional_trust_bundle=$(cat deps/$additional_trust_bundle_file) || \
		echo WARNING: No file $additional_trust_bundle_file

scripts/create-image-content-sources.sh 

[ -s $image_content_sources_file ] && \
	export image_content_sources=$(cat $image_content_sources_file) || \
		echo WARNING: No file $image_content_sources_file ...

[ -s $ssh_key_file ] && \
	export ssh_key_pub=$(cat $ssh_key_file) || \
		echo WARNING: No file $ssh_key_file ...

[ "$additional_trust_bundle" -a ! "$pull_secret" ] && echo && echo "Error: The registry cert is defined but the pull secret is not!" && exit 1
[ ! "$additional_trust_bundle" -a "$pull_secret" ] && echo && echo "Error: The pull secret is defined but the cert is not!" && exit 1

# Check the registry is defined if it's in use
if [ "$additional_trust_bundle" -a "$pull_secret" ]; then
	[ ! "$reg_host" ] && echo && echo "Error: registry host is not defined!" && exit 1
	[ ! "$reg_port" ] && echo && echo "Error: registry port is not defined!" && exit 1
fi

echo Generating Agent-based configuration file: $PWD/install-config.yaml 
j2 templates/install-config.yaml.j2 > install-config.yaml 

