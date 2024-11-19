#!/bin/bash 
# Find the available pull secrets and place them in the right locations: ~/.docker ~/.containers

source scripts/include_all.sh

public_pull_secret_file_needed=1  # Only needed for 'save' and 'sync'
[ "$1" = "--load" ] && public_pull_secret_file_needed= && shift
[ "$1" ] && set -x

umask 077

source <(normalize-aba-conf)

if [ ! -s $pull_secret_file -a "$public_pull_secret_file_needed" ]; then
	echo_red "Error: Your pull secret file '$pull_secret_file' does not exist! Download it from https://console.redhat.com/openshift/downloads#tool-pull-secret" >&2
	exit 1
fi

mkdir -p ~/.docker ~/.containers

# If the Red Hat creds are available merge them 
if [ -s regcreds/pull-secret-mirror.json -a -s $pull_secret_file ]; then
	# Merge the two files
	jq -s '.[0] * .[1]' ./regcreds/pull-secret-mirror.json $pull_secret_file > ./regcreds/pull-secret-full.json

	echo_cyan "Configuring ~/.docker/config.json with the pull secrets regcreds/pull-secret-mirror.json and regcreds/pull-secret-full.json ..."

	# Copy into place 
	cp ./regcreds/pull-secret-full.json ~/.docker/config.json
	cp ./regcreds/pull-secret-full.json ~/.containers/auth.json

# If the mirror creds are available add them also
elif [ -s regcreds/pull-secret-mirror.json ]; then
	echo_cyan "Configuring ~/.docker/config.json with the private mirror pull secret: regcreds/pull-secret-mirror.json ..."
	cp ./regcreds/pull-secret-mirror.json ~/.docker/config.json
	cp ./regcreds/pull-secret-mirror.json ~/.containers/auth.json

# Only use the Red Hat pull secret file
elif [ -s $pull_secret_file ]; then
	echo_cyan "Configuring ~/.docker/config.json with Red Hat pull secret $pull_secret_file ..."
	cp $pull_secret_file ~/.docker/config.json
	cp $pull_secret_file ~/.containers/auth.json  

else
	echo 
	echo_red "Aborting! Pull secret file(s) missing: '$pull_secret_file', 'regcreds/pull-secret-mirror.json' and/or 'regcreds/pull-secret-full.json'" >&2 

	exit 1
fi

