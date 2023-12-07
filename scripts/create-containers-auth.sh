#!/bin/bash 

. scripts/include_all.sh

[ "$1" ] && set -x

umask 077

install_rpm jq
install_pip j2cli

source mirror.conf

# This is the pull secret for RH registry
#pull_secret_mirror_file=pull-secret-mirror.json

#if [ -s $pull_secret_mirror_file ]; then
#	echo Using $pull_secret_mirror_file ...
#elif [ -s $pull_secret_file ]; then
#	:
#else
#	echo "Error: Your pull secret file [$pull_secret_file] does not exist! Download it from https://console.redhat.com/openshift/downloads#tool-pull-secret" && exit 1
#fi

mkdir -p ~/.docker ~/.containers

# If the mirror creds are available add them also
if [ -s ./registry-creds.txt ]; then
	reg_creds=$(cat ./registry-creds.txt)
	export enc_password=$(echo -n "$reg_creds" | base64 -w0)

	# Inputs: enc_password, reg_host and reg_port 
	j2 ./templates/pull-secret-mirror.json.j2 > ./deps/pull-secret-mirror.json

	# Merge the two files
	jq -s '.[0] * .[1]' ./deps/pull-secret-mirror.json $pull_secret_file > ./deps/pull-secret-full.json
	cp ./deps/pull-secret-full.json ~/.docker/config.json
	cp ./deps/pull-secret-full.json ~/.containers/auth.json
else
	echo Configuring ~/.docker/config.json and ~/.containers/auth.json with Red Hat pull secret ...
	cp $pull_secret_file ~/.docker/config.json
	cp $pull_secret_file ~/.containers/auth.json  
fi

