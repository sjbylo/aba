#!/bin/bash 
# Find the available pull secrets and place them in the right locations: ~/.docker ~/.containers

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

public_pull_secret_file_needed=1  # Only needed for 'save' and 'sync'
[ "$1" = "--load" ] && public_pull_secret_file_needed= && shift


umask 077

source <(normalize-aba-conf)

verify-aba-conf || exit 1

if [ "$public_pull_secret_file_needed" -a ! -s "$pull_secret_file" ]; then
	if [ ! "$pull_secret_file" ]; then
		aba_abort "Error: pull_secret_file not defined in aba.conf"
	fi

	aba_abort \
		"Error: Your pull secret file '$pull_secret_file' does not exist!" \
		"Download it from https://console.redhat.com/openshift/downloads#tool-pull-secret (select 'Tokens' in the pull-down)"
fi

aba_debug "Ensuring dirs exist: ~/.docker ~/.containers $XDG_RUNTIME_DIR/containers"
mkdir -p ~/.docker ~/.containers
[[ "$XDG_RUNTIME_DIR" == /* ]] && mkdir -p $XDG_RUNTIME_DIR/containers

# If the Red Hat creds are available merge them 
if [ -s regcreds/pull-secret-mirror.json -a -s $pull_secret_file ]; then
	# Merge the two files
	jq -s '.[0] * .[1]' ./regcreds/pull-secret-mirror.json $pull_secret_file > ./regcreds/pull-secret-full.json

	# Copy into place 
	aba_debug "Copying regcreds/pull-secret-full.json to ~/.docker/config.json and ~/.containers/auth.json"
	cp ./regcreds/pull-secret-full.json ~/.docker/config.json
	cp ./regcreds/pull-secret-full.json ~/.containers/auth.json
	if [[ "$XDG_RUNTIME_DIR" == /* ]]; then
		aba_debug "Copying regcreds/pull-secret-full.json to $XDG_RUNTIME_DIR/containers/auth.json" 
		cp ./regcreds/pull-secret-full.json $XDG_RUNTIME_DIR/containers/auth.json || true
	fi

# If the mirror creds are available add them also
elif [ -s regcreds/pull-secret-mirror.json ]; then
	aba_debug "Copying regcreds/pull-secret-mirror.json to ~/.docker/config.json and ~/.containers/auth.json"
	cp ./regcreds/pull-secret-mirror.json ~/.docker/config.json
	cp ./regcreds/pull-secret-mirror.json ~/.containers/auth.json
	if [[ "$XDG_RUNTIME_DIR" == /* ]]; then
		aba_debug "Copying regcreds/pull-secret-mirror.json to $XDG_RUNTIME_DIR/containers/auth.json" 
	       cp ./regcreds/pull-secret-mirror.json $XDG_RUNTIME_DIR/containers/auth.json || true
	fi

# Only use the Red Hat pull secret file
elif [ -s $pull_secret_file ]; then
	aba_debug "Copying $pull_secret_file to ~/.docker/config.json and ~/.containers/auth.json"
	cp $pull_secret_file ~/.docker/config.json
	cp $pull_secret_file ~/.containers/auth.json  
	if [[ "$XDG_RUNTIME_DIR" == /* ]]; then
		aba_debug "Copying $pull_secret_file to $XDG_RUNTIME_DIR/containers/auth.json" 
		cp $pull_secret_file $XDG_RUNTIME_DIR/containers/auth.json || true
	fi

else
	echo 
	aba_abort "Aborting! Pull secret file(s) missing: '$pull_secret_file', 'regcreds/pull-secret-mirror.json' and/or 'regcreds/pull-secret-full.json'" >&2 
fi

