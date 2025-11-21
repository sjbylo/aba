#!/bin/bash 
# Script to generate the install-config.yaml 

source scripts/include_all.sh

[ "$1" ] && export DEBUG_ABA=1
aba_debug "Starting: $0 $* at $(date) in dir: $PWD"


source <(normalize-aba-conf)
source <(normalize-cluster-conf)
source <(normalize-mirror-conf)
source <(normalize-vmware-conf)  # Some values needed for install-config.yaml

verify-aba-conf || exit 1
verify-cluster-conf || exit 1
verify-mirror-conf || exit 1

#to_output=$(normalize-cluster-conf | sed -e "s/^export //g" | paste -d '  ' - - - | column -t --output-separator " | ")
if [ "$platform" = "bm" ]; then
	to_output=$(normalize-cluster-conf | sed -E -e "s/^export //g" -e 's/^(mac_prefix|master_cpu_count|master_mem|worker_cpu_count|worker_mem|data_disk)=.*//g')
elif [ "$platform" = "vmw" ]; then
	to_output=$(normalize-cluster-conf | sed -e "s/^export //g")
fi
aba_info "Current values in cluster.conf:"
output_table 3 "$to_output"
echo

# Set the rendezvous_ip to the the first master's ip
export rendezvous_ip=$starting_ip

export pull_secret=
export ssh_key_pub=
export additional_trust_bundle=
export image_content_sources=

aba_debug rendezvous_ip: $starting_ip

# Change the default of bare-metal host prefix
if [ "$platform" = "bm" -a $hostPrefix -eq 23 ]; then
	aba_info "Adjusting the default host prefix from 23 to 22 for bare-metal servers."
	export hostPrefix=22
fi

# Generate the needed iso-agent-based config files ...

# Read in the needed files ...

# Which pull secret file to use?  If int_connection=proxy, then use the public pull secret, otherwise use the "mirror" pull secret by default.

use_mirror=1

# See if the cluster wide proxy should be added or not
if [ "$int_connection" = "direct" ]; then
	aba_info "Using direct internet access"

	use_mirror=
elif [ "$int_connection" = "proxy" ]; then
	# Else, if proxy is otherwise set, e.g. to 1 or true
	if [ "$http_proxy" -o "$https_proxy" ]; then
		# This means we will do an ONLINE install, using the public Red Hat registry. 
		if [ -s $pull_secret_file ]; then
			export pull_secret=$(cat $pull_secret_file | jq .)
			aba_info "Found pull secret file at $pull_secret_file.  Assuming online installation using public Red Hat registry."
		else
			aba_abort \
				"Error: No pull secret found at $pull_secret_file.  Aborting!  See the README.md file for help!" \
				"Get your pull secret from: https://console.redhat.com/openshift/downloads#tool-pull-secret (select 'Tokens' in the pull-down)" 
		fi

		aba_info_ok "Configuring 'cluster wide proxy' using the following proxy settings:"
		aba_info "  http_proxy=$http_proxy"
		aba_info "  https_proxy=$https_proxy"
		aba_info "  no_proxy=$no_proxy"

		# Using proxy! No need for these
		image_content_sources=
		additional_trust_bundle=

		export use_proxy=1
		use_mirror=
	else
		aba_warning "The proxy value in cluster.conf is set but not all proxy vars are set. Ignoring." \
			"If you want to configure the cluster wide proxy, set 'int_connection=proxy' or override by" \
			"setting the '*_proxy' values in 'cluster.conf'" 

		sleep 2
	fi
elif [ "$int_connection" ]; then
	aba_warning "Internet connection incorrectly defined in cluster.conf" >&2
else
	aba_info "Not configuring the Internet connectivity (proxy or direct) since values not set in cluster.conf."
fi

# If the proxy is not in use (usually the case in disco env), find the pull secret to use/prioritize the mirror ...
if [ "$use_mirror" ]; then
	if [ -s regcreds/pull-secret-mirror.json ]; then
		export pull_secret=$(cat regcreds/pull-secret-mirror.json) 
		aba_info Using mirror registry pull secret file at regcreds/pull-secret-mirror.json to access registry at: $reg_host

		# If we pull from the local reg. then we define the image content sources
		export image_content_sources=$(scripts/j2 templates/image-content-sources.yaml.j2)
	elif [ -s regcreds/pull-secret-full.json ]; then
		export pull_secret=$(cat regcreds/pull-secret-full.json) 
		aba_info Using mirror registry pull secret file at regcreds/pull-secret-full.json to access registry at: $reg_host

		# If we pull from the local reg. then we define the image content sources
		export image_content_sources=$(scripts/j2 templates/image-content-sources.yaml.j2)
	else
		aba_warning \
			"No pull secret files found in directory: aba/mirror/regcreds." \
			"A mirror registry has not been installed or configured!  See aba mirror --help."
		show_mirror_missing_err=1
	fi

	# ... we also, need a root CA... if using our own registry.
	if [ -s regcreds/rootCA.pem ]; then
		export additional_trust_bundle=$(cat regcreds/rootCA.pem) 
		aba_info "Using root CA file at regcreds/rootCA.pem"
	else
		# Only show this warning IF there is no internet connection?
		# Or, only show if proxy is NOT being used?
		#if [ "$use_proxy" ]; then
		#	echo_red "No private mirror registry configured! Using proxy settings to access Red Hat's public registry." >&2
		#else
		# Should check accessibility to registry.redhat.io?
			aba_warning \
				"Root CA file missing: aba/mirror/regcreds/rootCA.pem." \
				"No private mirror registry available!" \
				"As a result, no 'additionalTrustBundle' will be added to 'install-config.yaml'."

			show_mirror_missing_err=1
		#fi
	fi

	if [ "$show_mirror_missing_err" ]; then
		aba_warning \
			"No internet connection (proxy or direct) has been defined in cluster.conf." \
			"If this is *unexpected*, either install/set up a mirror registry or define internet connectivity in $PWD/cluster.conf." \
			"Refer to the README.md for more." 

		sleep 2
	fi
fi

# If not already set, set the default value
if [ ! "$pull_secret" ]; then
	if [ -s "$pull_secret_file" ]; then
		export pull_secret=$(cat "$pull_secret_file" | jq .) 
		aba_info Using pull secret file at $pull_secret_file to access Red Hat registry
		# Note, no image_content_sources needed
		export image_content_sources=
	else
		aba_abort "Pull secret file missing: $pull_secret_file"
	fi
fi

# Check for ssh key files 
if [ -s $ssh_key_file.pub ]; then
	aba_info Using existing ssh key files: $ssh_key_file ... 
else
	aba_info "Creating ssh key files for $ssh_key_file ..."
	ssh-keygen -t rsa -f $ssh_key_file -N ''
fi
export ssh_key_pub=$(cat $ssh_key_file.pub) 


# Check the private registry is defined, if it's in use
if [ "$additional_trust_bundle" -a "$pull_secret" ]; then
	[ ! "$reg_host" ] && aba_abort "Error: registry host value reg_host is not defined in mirror.conf!"
fi

# Check that the release image is available in the private registry
if [ "$additional_trust_bundle" -a "$image_content_sources" ]; then
	scripts/create-containers-auth.sh --load
	scripts/verify-release-image.sh
fi

#if [ "$INFO_ABA" ]; then
	aba_info
	aba_info Generating Agent-based configuration file: $PWD/install-config.yaml 
	aba_info
#fi

# Input is additional_trust_bundle, ssh_key_pub, image_content_sources, pull_secret, use_proxy, arch ...
aba_debug Creating install-config.yaml ...
[ -s install-config.yaml ] && cp install-config.yaml install-config.yaml.backup
scripts/j2 templates/install-config.yaml.j2 > install-config.yaml

aba_info_ok "$PWD/install-config.yaml generated successfully!"
echo

