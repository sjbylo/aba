#!/bin/bash
# Verify the CLI versions match the mirror images

source scripts/include_all.sh

[ "$1" ] && set -x

if [ ! -x ~/bin/openshift-install ]; then
	[ "$TERM" ] && tput setaf 1
	echo
	echo "The ~/bin/openshift-install CLI is missing!  Please run ./aba first."
	echo
	[ "$TERM" ] && tput sgr0
	exit 1
fi

source <(normalize-aba-conf)
source <(normalize-mirror-conf)

release_sha=$(openshift-install version| grep "release image" | sed "s/.*\(@sha.*$\)/\1/g")
release_ver=$(openshift-install version| grep "^openshift-install" | cut -d" " -f2)

if [ "$ocp_version" != "$release_ver" ]; then
	[ "$TERM" ] && tput setaf 1
	echo
	echo "WARNING: The OpenShift version set in 'aba.conf' is not the same as the version of the 'openshift-install' CLI." 
	echo "Please run 'make -C cli clean' and try again." 
	echo
	[ "$TERM" ] && tput sgr0

	exit 1
fi


[ ! "$tls_verify" ] && tls_verify_opts="--tls-verify=false"

if ! skopeo inspect $tls_verify_opts docker://$reg_host:$reg_port/$reg_path/openshift/release-images$release_sha >/dev/null; then

	[ "$TERM" ] && tput setaf 1
	echo
	echo "Error: There was an error whilst checking for the release image (expected version $release_ver) in your registry at $reg_host:$reg_port/!"
	echo "       Did you remember to 'sync' or 'save/load' the images into your registry?"
	echo "       Be sure that the images in your registry match the version of the 'openshift-install' CLI (currently version $release_ver)"
	echo "       Failed to access the release image: docker://$reg_host:$reg_port/$reg_path/openshift/release-images$release_sha"
	[ "$TERM" ] && tput sgr0

	exit 1
fi

echo "Release image for version $release_ver is available in $reg_host:$reg_port"

