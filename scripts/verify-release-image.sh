#!/bin/bash
# Verify the CLI versions match the mirror images

source scripts/include_all.sh

[ "$1" ] && set -x

#[ -s mirror/mirror.conf ] && source mirror/mirror.conf || source mirror.conf
source mirror.conf

release_sha=$(openshift-install version| grep "release image" | sed "s/.*\(@sha.*$\)/\1/g")

[ ! "$tls_verify" ] && tls_verify_opts="--tls-verify=false"

if ! skopeo inspect $tls_verify_opts docker://$reg_host:$reg_port/openshift4/openshift/release-images$release_sha >/dev/null; then
	echo
	echo "Error: There was an error whilst checking for the expected release image in your registry!"
	echo "       Be sure to install the correct oc, openshift-install, oc-mirror versions and try again!"
	echo "       Failed to access the release image: docker://$reg_host:$reg_port/openshift4/openshift/release-images$release_sha"

	exit 1
fi

echo "Release image is available in $reg_host:$reg_port"

