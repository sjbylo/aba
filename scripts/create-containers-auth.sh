#!/bin/bash 
# Find the available pull secrets and place them in the right locations: ~/.docker ~/.containers

. scripts/include_all.sh

[ "$1" ] && set -x

umask 077

source aba.conf
source mirror.conf

# This is the pull secret for RH registry
#pull_secret_mirror_file=pull-secret-mirror.json

#if [ -s $pull_secret_mirror_file ]; then
#	echo Using $pull_secret_mirror_file ...
#elif [ -s ~/.pull-secret.json ]; then
#	:
#else
#	echo "Error: Your pull secret file [~/.pull-secret.json] does not exist! Download it from https://console.redhat.com/openshift/downloads#tool-pull-secret" && exit 1
#fi

mkdir -p ~/.docker ~/.containers

# If the mirror creds are available add them also
##if [ -s ./.registry-creds.txt ]; then
##	reg_creds=$(cat ./.registry-creds.txt)   # FIXME: this file is not needed!
##	export enc_password=$(echo -n "$reg_creds" | base64 -w0)
##
##	# Inputs: enc_password, reg_host and reg_port 
##	scripts/j2 ./templates/pull-secret-mirror.json.j2 > ./regcreds/pull-secret-mirror.json
##fi

# If the Red Hat creds are available merge them 
if [ -s regcreds/pull-secret-mirror.json -a -s ~/.pull-secret.json ]; then
	# Merge the two files
	jq -s '.[0] * .[1]' ./regcreds/pull-secret-mirror.json ~/.pull-secret.json > ./regcreds/pull-secret-full.json

	cp ./regcreds/pull-secret-full.json ~/.docker/config.json
	cp ./regcreds/pull-secret-full.json ~/.containers/auth.json

# If the mirror creds are available add them also
elif [ -s regcreds/pull-secret-mirror.json ]; then
	cp ./regcreds/pull-secret-mirror.json ~/.docker/config.json
	cp ./regcreds/pull-secret-mirror.json ~/.containers/auth.json
else
	# Just use the Red Hat pull secret file
	echo Configuring ~/.docker/config.json and ~/.containers/auth.json with Red Hat pull secret ~/.pull-secret.json ...
	cp ~/.pull-secret.json ~/.docker/config.json
	cp ~/.pull-secret.json ~/.containers/auth.json  
fi

