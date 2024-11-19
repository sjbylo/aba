#!/bin/bash

source scripts/include_all.sh

[ "$1" ] && set -x

umask 077

source <(normalize-aba-conf)
###source <(normalize-mirror-conf)

if [ -s $pull_secret_file ]; then
	if ! grep -q registry.redhat.io $pull_secret_file; then
		echo "Was expecting to see the string 'registry.redhat.io' in your pull secret."
		echo "The format of your pull secret looks wrong, please fix it and try again!"

		exit 1
	else
		echo "Red Hat pull secret found at $pull_secret_file"

		exit 0
	fi
fi

echo
echo_red "Error: To download images from Red Hat's registry, a pull secret is required." >&2
echo_red "       Please fetch your pull secret from https://console.redhat.com/openshift/downloads#tool-pull-secret" >&2
echo_red "       and save it to the file $pull_secret_file in your home directory." >&2
echo

exit 1

