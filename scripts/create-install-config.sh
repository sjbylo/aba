#!/bin/bash 
# Script to generate the install-config.yaml 

. scripts/include_all.sh

[ "$1" ] && set -x

source aba.conf
source mirror.conf
[ -s vmware.conf ] && source vmware.conf

scripts/verify-release-image.sh


# Set the rendezvous_ip to the the first master's ip
export machine_ip_prefix=$(echo $machine_network | cut -d\. -f1-3).
export rendezvous_ip=$machine_ip_prefix$starting_ip_index

#SNO=
#[ $num_masters -eq 1 -a $num_workers -eq 0 ] && SNO=1 && echo Configuring for SNO ...

##echo Validating the cluster configuraiton ...

export pull_secret=
export ssh_key_pub=
export additional_trust_bundle=
export image_content_sources=

# FIXME - add to makefile
ln -fs ../mirror/regcreds 

# Generate the needed iso-agent-based config files ...

# Read in the needed files ...

if [ -s regcreds/pull-secret-mirror.json ]; then
	export pull_secret=$(cat regcreds/pull-secret-mirror.json) 
	echo Using mirror registry pull secret file at regcreds/pull-secret-mirror.json to access registry at $reg_host

	# If we pull from the local reg. then we define the image content sources
	##[ -s templates/image-content-sources.yaml.j2 ] && \
		export image_content_sources=$(scripts/j2 templates/image-content-sources.yaml.j2) #|| \
			# echo WARNING: No file templates/image-content-sources.yaml.j2

	# ... we also, need a root CA...
	if [ -s regcreds/rootCA.pem ]; then
		export additional_trust_bundle=$(cat regcreds/rootCA.pem) 
		echo "Using root CA file at regcreds/rootCA.pem"
	else	
		echo "Warning: No file rootCA.pem.  Assuming mirror registry is using http."
		##  exit 1  # Will only work without a cert if the registry is using http
	fi
else
	#echo WARNING: No mirror registry pull secret file found at regcreds/pull-secret-mirror.json.  Trying to use ./pull-secret.json.
	if [ -s $pull_secret_file ]; then
		export pull_secret=$(cat $pull_secret_file)
		echo Found pull secret file at $pull_secret_file
	else
		echo "Error: No pull secrets found. Aborting!" 
		exit 1
	fi
fi

[ -s $ssh_key_file ] && \
	export ssh_key_pub=$(cat $ssh_key_file) || \
		echo WARNING: No file $ssh_key_file ...

# Check the registry is defined if it's in use
if [ "$additional_trust_bundle" -a "$pull_secret" ]; then
	[ ! "$reg_host" ] && echo && echo "Error: registry host is not defined!" && exit 1
fi

echo
echo Generating Agent-based configuration file: $PWD/install-config.yaml 
echo
# Input is additional_trust_bundle, ssh_key_pub, image_content_sources, pull_secret ...
[ -s install-config.yaml ] && cp install-config.yaml install-config.yaml.backup
scripts/j2 templates/install-config.yaml.j2 > install-config.yaml

