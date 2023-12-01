#!/bin/bash
# Verify the CLI versions match the mirror images

[ -s mirror/mirror.conf ] && source mirror/mirror.conf || source mirror.conf

image=$(openshift-install version| grep "release image" | sed "s/.*\(@sha.*$\)/\1/g")

rpm --quiet -q skopeo >/dev/null 2>&1 || sudo dnf install skopeo -y >/dev/null 

echo "Verifying the release image: docker://$reg_host:$reg_port/openshift4/openshift/release-images$image"

if ! skopeo inspect docker://$reg_host:$reg_port/openshift4/openshift/release-images$image >/dev/null; then
	echo
	echo "Error: The $(which openshift-install) CLI version not match the release image version in your registry!"
	echo "       Be sure to in stall the correct oc, openshift-install, oc-mirror versions and try again!"
	exit 1
fi

#[steve@bastion1 cli]$ skopeo inspect docker://registry.example.com:8443/openshift4/openshift/release-images@sha256:e73ab4b33a9c3ff00c9f800a38d69853ca0c4dfa5a88e3df331f66df8f18ec55  ^C


