#!/bin/bash

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

[ "$1" ] && set -x

umask 077

source <(normalize-aba-conf)

verify-aba-conf || exit 1

###source <(normalize-mirror-conf)

# Pull secret file exists
if [ -s $pull_secret_file ]; then
	# ... contains expected registry
	if grep -q registry.redhat.io $pull_secret_file; then
		# ... is the correct json format
		if jq empty $pull_secret_file; then
			echo "Valid Red Hat pull secret found at $pull_secret_file"

			exit 0
		else
			echo
			echo_red "Error: Syntax error in your pull secret file at $pull_secret_file. Fix it and try again!" >&2
			echo_white "Get your pull secret from: https://console.redhat.com/openshift/downloads#tool-pull-secret (select 'Tokens' in the pull-down)" >&2
			echo

			exit 1
		fi
	else
		echo "Expected to see the string 'registry.redhat.io' in your pull secret file at $pull_secret_file" >&2
		echo "The format of your pull secret file looks wrong, fix it and try again!" >&2
		echo_white "Get your pull secret from: https://console.redhat.com/openshift/downloads#tool-pull-secret (select 'Tokens' in the pull-down)" >&2

		exit 1
	fi
fi

echo
echo_red "Error: To download images from Red Hat's registry, a pull secret is required." >&2
echo_red "       Fetch your pull secret from https://console.redhat.com/openshift/downloads#tool-pull-secret (select 'Tokens' in the pull-down)" >&2
echo_red "       and save it to the file $pull_secret_file." >&2
echo

exit 1

