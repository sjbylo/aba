#!/bin/bash
# Verify the correct/matching release image exists in the registry. Required access to the registry of course!

source scripts/include_all.sh

[ "$1" ] && set -x

if [ ! -x ~/bin/openshift-install ]; then
	echo
	echo_red "The ~/bin/openshift-install CLI is missing!  Please run ./aba first."
	echo

	exit 1
fi

source <(normalize-aba-conf)
source <(normalize-mirror-conf)

out=$(openshift-install version)
release_sha=$(echo "$out" | grep "release image" | sed "s/.*\(@sha.*$\)/\1/g")
release_ver=$(echo "$out" | grep "^openshift-install" | cut -d" " -f2)

if [ "$ocp_version" != "$release_ver" ]; then
	echo
	echo_red "Warning: The OpenShift version set in 'aba.conf' is not the same as the version of the 'openshift-install' CLI." 
	echo_red "         Please run 'make -C cli' and try again." 
	echo

	exit 1
fi


[ ! "$tls_verify" ] && tls_verify_opts="--tls-verify=false"

if ! skopeo inspect $tls_verify_opts docker://$reg_host:$reg_port/$reg_path/openshift/release-images$release_sha >/dev/null; then
	echo
	echo_red "Error: Release image missing in your registry at $reg_host:$reg_port/$reg_path. Expected version is $release_ver."
	echo_red "       Did you remember to 'sync' or 'save/load' the images into your registry?"
	echo_red "       Be sure that the images in your registry match the version of the 'openshift-install' CLI (currently version $release_ver)"
	echo_red "       Do you have the correct image versions in your registry?"
	echo_red "       Failed to access the release image: docker://$reg_host:$reg_port/$reg_path/openshift/release-images$release_sha"

	exit 1
fi

echo_green "Release image for version $release_ver is available at $reg_host:$reg_port/$reg_path/openshift/release-images$release_sha"

