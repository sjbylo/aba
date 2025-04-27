#!/bin/bash 
# Script to generate the install-config.yaml 

source scripts/include_all.sh

[ "$1" ] && set -x

source <(normalize-aba-conf)
source <(normalize-cluster-conf)
source <(normalize-mirror-conf)
#[ -s vmware.conf ] && source <(normalize-vmware-conf)  # Some values needed for install-config.yaml
source <(normalize-vmware-conf)  # Some values needed for install-config.yaml

verify-aba-conf || exit 1
verify-cluster-conf || exit 1
verify-mirror-conf || exit 1

#to_output=$(normalize-cluster-conf | sed -e "s/^export //g" | paste -d '  ' - - - | column -t --output-separator " | ")
to_output=$(normalize-cluster-conf | sed -e "s/^export //g")
echo_white "Current values in cluster.conf:"
output_table 3 "$to_output"
echo

# Set the rendezvous_ip to the the first master's ip
export rendezvous_ip=$starting_ip

export pull_secret=
export ssh_key_pub=
export additional_trust_bundle=
export image_content_sources=

# Change the default of bare-metal host prefix
if [ "$platform" = "bm" -a $hostPrefix -eq 23 ]; then
	echo_cyan "Adjusting the default host prefix from 23 to 22 for bare-metal servers."
	export hostPrefix=22
fi

# Generate the needed iso-agent-based config files ...

# Read in the needed files ...

# Which pull secret file to use?  If int_connection=proxy, then use the public pull secret, otherwise use the "mirror" pull secret by default.

use_mirror=1

# See if the cluster wide proxy should be added or not
if [ "$int_connection" = "direct" ]; then
	echo_white "Using direct internet access"

	use_mirror=
elif [ "$int_connection" = "proxy" ]; then
	# Else, if proxy is otherwise set, e.g. to 1 or true
	if [ "$http_proxy" -o "$https_proxy" ]; then
		# This means we will do an ONLINE install, using the public Red Hat registry. 
		if [ -s $pull_secret_file ]; then
			export pull_secret=$(cat $pull_secret_file | jq .)
			[ "$INFO_ABA" ] && echo Found pull secret file at $pull_secret_file.  Assuming online installation using public Red Hat registry.
		else
			echo_red "Error: No pull secret found at $pull_secret_file.  Aborting!  See the README.md file for help!" >&2 
			echo_white "Get your pull secret from: https://console.redhat.com/openshift/downloads#tool-pull-secret (select 'Tokens' in the pull-down)" >&2

			exit 1
		fi

		[ "$INFO_ABA" ] && echo_green "Configuring 'cluster wide proxy' using the following proxy settings:"
		[ "$INFO_ABA" ] && echo_white "  http_proxy=$http_proxy"
		[ "$INFO_ABA" ] && echo_white "  https_proxy=$https_proxy"
		[ "$INFO_ABA" ] && echo_white "  no_proxy=$no_proxy"

		# Using proxy! No need for these
		image_content_sources=
		additional_trust_bundle=

		export use_proxy=1
		use_mirror=
	else
		echo_red "Warning: The proxy value in cluster.conf is set but not all proxy vars are set. Ignoring." >&2
		echo_red "If you want to configure the cluster wide proxy, set 'int_connection=proxy' or override by" >&2
		echo_red "setting the '*_proxy' values in 'cluster.conf'" >&2

		sleep 2
	fi
elif [ "$int_connection" ]; then
	echo_red "Warning: Internet connectivity incorrectly defined in cluster.conf" >&2
else
	[ "$INFO_ABA" ] && echo_white "Not configuring the Internet connectivity (proxy or direct) since values not set in cluster.conf."
fi

# If the proxy is not in use (usually the case), find the pull secret to use ... prioritize the mirror ...
#if [ ! "$use_proxy" -a ! "$use_direct" ]; then
if [ "$use_mirror" ]; then
	if [ -s regcreds/pull-secret-mirror.json ]; then
		export pull_secret=$(cat regcreds/pull-secret-mirror.json) 
		echo_white Using mirror registry pull secret file at regcreds/pull-secret-mirror.json to access registry at: $reg_host

		# If we pull from the local reg. then we define the image content sources
		export image_content_sources=$(scripts/j2 templates/image-content-sources-$oc_mirror_version.yaml.j2)
	elif [ -s regcreds/pull-secret-full.json ]; then
		export pull_secret=$(cat regcreds/pull-secret-full.json) 
		echo_white Using mirror registry pull secret file at regcreds/pull-secret-full.json to access registry at: $reg_host

		# If we pull from the local reg. then we define the image content sources
		export image_content_sources=$(scripts/j2 templates/image-content-sources-$oc_mirror_version.yaml.j2)
	else
		echo_red "Warning: No pull secret files found in directory: aba/mirror/regcreds." >&2 
		show_mirror_missing_err=1
	fi

	# ... we also, need a root CA... if using our own registry.
	if [ -s regcreds/rootCA.pem ]; then
		export additional_trust_bundle=$(cat regcreds/rootCA.pem) 
		echo "Using root CA file at regcreds/rootCA.pem"
	else
		# Only show this warning IF there is no internet connection?
		# Or, only show if proxy is NOT being used?
		#if [ "$use_proxy" ]; then
		#	echo_red "No private mirror registry configured! Using proxy settings to access Red Hat's public registry." >&2
		#else
		# Should check accessibility to registry.redhat.io?
			echo_red "Warning: Root CA file missing: aba/mirror/regcreds/rootCA.pem." >&2
			echo_red "         No private mirror registry available!" >&2
			echo_red "         As a result, no 'additionalTrustBundle' will be added to 'install-config.yaml'." >&2

			show_mirror_missing_err=1
		#fi
	fi

	if [ "$show_mirror_missing_err" ]; then
		echo_red "         No internet connectivity (proxy or direct) has been defined in cluster.conf." >&2
		echo_red "         If this is *unexpected*, either set up a mirror registry or define internet connectivity. Refer to the README.md for detailed instructions." >&2

		sleep 2
	fi
fi

# If not already set, set the default value
if [ ! "$pull_secret" ]; then
	if [ -s "$pull_secret_file" ]; then
		export pull_secret=$(cat "$pull_secret_file" | jq .) 
		echo_white Using pull secret file at $pull_secret_file to access Red Hat registry
		# Note, no image_content_sources needed
		export image_content_sources=
	else
		echo_red "Error: Pull secret file missing: $pull_secret_file"

		exit 1
	fi
fi

# Check for ssh key files 
if [ -s $ssh_key_file.pub ]; then
	[ "$INFO_ABA" ] && echo Using existing ssh key files: $ssh_key_file ... 
else
	echo Creating ssh key files for $ssh_key_file ... 
	ssh-keygen -t rsa -f $ssh_key_file -N ''
fi
export ssh_key_pub=$(cat $ssh_key_file.pub) 


# Check the private registry is defined, if it's in use
if [ "$additional_trust_bundle" -a "$pull_secret" ]; then
	[ ! "$reg_host" ] && echo && echo_red "Error: registry host value reg_host is not defined in mirror.conf!" >&2 && exit 1
fi

# Check that the release image is available in the private registry
if [ "$additional_trust_bundle" -a "$image_content_sources" ]; then
	scripts/create-containers-auth.sh --load
####	scripts/verify-release-image.sh
fi

if [ "$INFO_ABA" ]; then
	echo
	echo Generating Agent-based configuration file: $PWD/install-config.yaml 
	echo
fi

# Added to include all sh
#export arch=$(uname -m)
#[ "$arch" = "aarch64" ] && arch=arm64  # ARM
#[ "$arch" = "x86_64" ] && arch=amd64   # Intel

# Input is additional_trust_bundle, ssh_key_pub, image_content_sources, pull_secret, use_proxy, arch ...
[ -s install-config.yaml ] && cp install-config.yaml install-config.yaml.backup
scripts/j2 templates/install-config.yaml.j2 > install-config.yaml

echo_green "$PWD/install-config.yaml generated successfully!"
echo

