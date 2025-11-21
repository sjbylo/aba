#!/bin/bash

# FIXME: Does this script do anything, other than verify?

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

umask 077

source <(normalize-aba-conf)

verify-aba-conf || exit 1

# Pull secret file exists
if [ -s $pull_secret_file ]; then
	# ... contains expected registry
	if grep -q registry.redhat.io $pull_secret_file; then
		# ... is the correct json format
		if jq empty $pull_secret_file; then
			aba_info "Valid Red Hat pull secret found at $pull_secret_file"

			exit 0
		else
			aba_abort \
				"Syntax error in your pull secret file at $pull_secret_file. Fix it and try again!" \
				"Get your pull secret from: https://console.redhat.com/openshift/downloads#tool-pull-secret (select 'Tokens' in the pull-down)"
		fi
	else
		aba_abort \
			"Expected to see the string 'registry.redhat.io' in your pull secret file at $pull_secret_file" \
			"The format of your pull secret file looks wrong, fix it and try again!" \
			"Get your pull secret from: https://console.redhat.com/openshift/downloads#tool-pull-secret (select 'Tokens' in the pull-down)"
	fi
fi

aba_abort \
	"To download images from Red Hat's registry, a pull secret is required." \
	"Fetch your pull secret from https://console.redhat.com/openshift/downloads#tool-pull-secret (select 'Tokens' in the pull-down)" \
	"and save it to the file $pull_secret_file."

exit 1

