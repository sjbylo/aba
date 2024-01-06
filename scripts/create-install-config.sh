#!/bin/bash 
# Script to generate the install-config.yaml 

. scripts/include_all.sh

[ "$1" ] && set -x

source aba.conf
source mirror.conf

scripts/verify-release-image.sh

install_rpm bind-utils nmstate python3-pip
#install_pip j2cli


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
ln -fs ../mirror/deps 

# Generate the needed iso-agent-based config files ...

# Read in the needed files ...

if [ -s deps/pull-secret-mirror.json ]; then
	export pull_secret=$(cat deps/pull-secret-mirror.json) 
	echo Using mirror registry pull secret file at deps/pull-secret-mirror.json

	# If we pull from the local reg. then we define the image content sources
	##[ -s templates/image-content-sources.yaml.j2 ] && \
		export image_content_sources=$(scripts/j2 templates/image-content-sources.yaml.j2) #|| \
			# echo WARNING: No file templates/image-content-sources.yaml.j2

	# ... we also, need a root CA...
	if [ -s deps/rootCA.pem ]; then
		export additional_trust_bundle=$(cat deps/rootCA.pem) 
		echo Using root CA file at deps/rootCA.pem
	else	
		echo ERROR: No file rootCA.pem
		exit 1
	fi
else
	#echo WARNING: No mirror registry pull secret file found at deps/pull-secret-mirror.json.  Trying to use ./pull-secret.json.
	if [ -s ~/.pull-secret.json ]; then
		export pull_secret=$(cat ~/.pull-secret.json)
		echo Found pull secret file at ~/.pull-secret.json
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

echo Generating Agent-based configuration file: $PWD/install-config.yaml 
# Input is additional_trust_bundle, ssh_key_pub, image_content_sources, pull_secret ...
scripts/j2 templates/install-config.yaml.j2 > install-config.yaml2

exit 0

scripts/render_template.py --template install-config.yaml.j2 \
	cluster_name \
	base_domain \
	num_masters \
	num_workers \
	additional_trust_bundle \
	api_vip \
	ingress_vip \
	image_content_sources \
	machine_network \
	prefix_length \
	pull_secret \
	ssh_key_pub \
		> install-config.yaml 

#echo "scripts/render_template.py --template install-config.yaml.j2 \
	#cluster_name="$cluster_name" \
	#base_domain="$base_domain" \
	#num_masters="$num_masters" \
	#num_workers="$num_workers" \
	#additional_trust_bundle="$additional_trust_bundle" \
	#api_vip="$api_vip" \
	#ingress_vip="$ingress_vip" \
	#image_content_sources="$image_content_sources" \
	#machine_network="$machine_network" \
	#prefix_length="$prefix_length" \
	#pull_secret="$pull_secret" \
	#ssh_key_pub="$ssh_key_pub" \
		#> install-config.yaml "

