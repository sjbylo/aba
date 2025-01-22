#!/bin/bash 
# Script to generate the install-config.yaml 

source scripts/include_all.sh

[ "$1" ] && set -x

source <(normalize-aba-conf)
source <(normalize-cluster-conf)
source <(normalize-mirror-conf)
[ -s vmware.conf ] && source <(normalize-vmware-conf)

# Set the rendezvous_ip to the the first master's ip
##export machine_ip_prefix=$(echo $machine_network | cut -d\. -f1-3).
#export rendezvous_ip=$machine_ip_prefix$starting_ip
export rendezvous_ip=$starting_ip

export pull_secret=
export ssh_key_pub=
export additional_trust_bundle=
export image_content_sources=
###export insert_proxy=

# Change the default of bare-metal host prefix
if [ "$platform" = "bm" -a $hostPrefix -eq 23 ]; then
	echo_cyan "Adjusting the default host prefix from 23 to 22 for bare-metal servers."
	export hostPrefix=22
fi

# Generate the needed iso-agent-based config files ...

# Read in the needed files ...

if [ -s regcreds/pull-secret-full.json ]; then
	export pull_secret=$(cat regcreds/pull-secret-full.json) 
	echo Using mirror registry pull secret file at regcreds/pull-secret-full.json to access registry at $reg_host

	# If we pull from the local reg. then we define the image content sources
	export image_content_sources=$(scripts/j2 templates/image-content-sources.yaml.j2)

elif [ -s regcreds/pull-secret-mirror.json ]; then
	export pull_secret=$(cat regcreds/pull-secret-mirror.json) 
	echo Using mirror registry pull secret file at regcreds/pull-secret-mirror.json to access registry at $reg_host

	# If we pull from the local reg. then we define the image content sources
	export image_content_sources=$(scripts/j2 templates/image-content-sources.yaml.j2)

else
	# This means we will do an ONLINE install, using the public RH registry. 
	if [ -s $pull_secret_file ]; then
		export pull_secret=$(cat $pull_secret_file)
		echo Found pull secret file at $pull_secret_file.  Assuming online installation using public RH registry.
	else
		echo_red "Error: No pull secrets found. Aborting!  See the README for help!" >&2 

		exit 1
	fi
fi


# Check for ssh key files 
if [ -s $ssh_key_file.pub ]; then
	echo Using existing ssh key files: $ssh_key_file ... 
else
	echo Creating ssh key files for $ssh_key_file ... 
	ssh-keygen -t rsa -f $ssh_key_file -N ''
fi
export ssh_key_pub=$(cat $ssh_key_file.pub) 


# See if the cluster wide proxy should be added
#if [ "$set_http_proxy" -a "$set_https_proxy" ]; then
#	export http_proxy=$set_http_proxy
#	export https_proxy=$set_https_proxy
#	export no_proxy=$set_no_proxy
#if [ "$http_proxy" -a "$https_proxy" ]; then
if [ "$proxy" ]; then
	if [ "$http_proxy" -a "$https_proxy" ]; then
		[ "$INFO_ABA" ] && echo_green "Configuring 'cluster wide proxy' using the following proxy settings:"
		[ "$INFO_ABA" ] && echo_white "  http_proxy=$http_proxy"
		[ "$INFO_ABA" ] && echo_white "  https_proxy=$https_proxy"
		[ "$INFO_ABA" ] && echo_white "  no_proxy=$no_proxy"

		###export insert_proxy=$(scripts/j2 templates/install-config-proxy.j2)

		# Using proxy! No need for this
		image_content_sources=
		additional_trust_bundle=

		insert_proxy=1
	else
		echo_red "Warning: The proxy value in cluster.conf is set but not all proxy vars are set. Ignoring." >&2
		echo_red "If you want to configure the cluster wide proxy, set 'proxy=1' or override by" >&2
		echo_red "setting the '*_proxy' values in 'cluster.conf'" >&2
	fi
else
	echo_white "Not configuring the cluster wide proxy since proxy values not set in cluster.conf."
fi

# ... we also, need a root CA... if using our own registry.
if [ -s regcreds/rootCA.pem ]; then
	export additional_trust_bundle=$(cat regcreds/rootCA.pem) 
	echo "Using root CA file at regcreds/rootCA.pem"
else
	# Only show this warning IF there is no internet connection?
	# Or, only show if proxy is NOT being used?
	if [ "$insert_proxy" ]; then
		echo_red "No private mirror registry configured! Using proxy settings to access public registry." >&2
	else
		# Should check accessibility to registry.redhat.io?
		echo
		##echo_red "Warning: No private mirror registry configured & no proxy settings provided!" >&2
		##echo_red "         If this is *unexpected* you likely need to set up a mirror registry! See the README.md for more." >&2
		##echo_red "         Root CA file 'regcreds/rootCA.pem' not found. Not adding 'additionalTrustBundle' to install-config.yaml!" >&2
		echo_red "Warning: No private mirror registry is configured, and no proxy settings have been provided!" >&2
		echo_red "         If this is *unexpected*, setting up a mirror registry may be necessary. Refer to the README.md for detailed instructions." >&2
		echo_red "         Root CA file 'regcreds/rootCA.pem' is missing. As a result, the 'additionalTrustBundle' will not be added to 'install-config.yaml'." >&2
	fi
fi

# Check the private registry is defined, if it's in use
if [ "$additional_trust_bundle" -a "$pull_secret" ]; then
	[ ! "$reg_host" ] && echo && echo_red "Error: registry host value reg_host is not defined in mirror.conf!" >&2 && exit 1
fi

# Check that the release image is available in the private registry
if [ "$additional_trust_bundle" -a "$image_content_sources" ]; then
	scripts/create-containers-auth.sh --load
	scripts/verify-release-image.sh
fi

echo
echo Generating Agent-based configuration file: $PWD/install-config.yaml 
echo
# Input is additional_trust_bundle, ssh_key_pub, image_content_sources, pull_secret, insert_proxy ...
[ -s install-config.yaml ] && cp install-config.yaml install-config.yaml.backup
scripts/j2 templates/install-config.yaml.j2 > install-config.yaml

echo_green "$PWD/install-config.yaml generated successfully!"
echo
