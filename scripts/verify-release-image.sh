#!/bin/bash
# Verify the CLI versions match the mirror images

source scripts/include_all.sh

[ "$1" ] && set -x

#[ -s mirror/mirror.conf ] && source mirror/mirror.conf || source mirror.conf
source mirror.conf

release_image=$(openshift-install version| grep "release image" | sed "s/.*\(@sha.*$\)/\1/g")

install_rpm skopeo

#echo "Verifying the release image: docker://$reg_host:$reg_port/openshift4/openshift/release-images$release_image"

if ! skopeo inspect docker://$reg_host:$reg_port/openshift4/openshift/release-images$release_image >/dev/null; then
	echo
	echo "Error: The expected release image using the $(which openshift-install) CLI was not found in your registry!"
	echo "       Be sure to install the correct oc, openshift-install, oc-mirror versions and try again!"
	echo "       Failed to access the release image: docker://$reg_host:$reg_port/openshift4/openshift/release-images$release_image"
	exit 1
fi

echo "Release image is available in $reg_host:$reg_port"

