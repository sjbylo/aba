#!/bin/bash -e
# Create the pull secret for your existing mirror registry.
# Usage: aba -d mirror -H myreg.example.com password 

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

source <(normalize-aba-conf)
source <(normalize-mirror-conf)

read -p "Enter username [init]: " reg_user
[ ! "$reg_user" ] && reg_user=init 

read -sp "Enter password: " reg_pw
echo

export enc_password=$(echo -n "$reg_user:$reg_pw" | base64 -w0)

mkdir -p regcreds
# Inputs: enc_password, reg_host and reg_port 
scripts/j2 ./templates/pull-secret-mirror.json.j2 > ./regcreds/.pull-secret-mirror.json

# Note that for https, the installation of OCP *will* require the registry's root certificate 
podman logout --all >/dev/null
if podman login --tls-verify=false --authfile=regcreds/.pull-secret-mirror.json  $reg_host:$reg_port; then
	mv regcreds/.pull-secret-mirror.json regcreds/pull-secret-mirror.json
else
	rm -f regcreds/.pull-secret-mirror.json
fi

[ ! -s regcreds/rootCA.pem ] && \
	aba_warning -p IMPORTANT \
		"Fetch the root CA file for $reg_host and copy it to $PWD/regcreds/rootCA.pem.  After the file is in place, run: aba -d mirror verify"

# Add flag so 'aba -d mirror install' is complete.  Assume the user will also add the rootCA.pem file to complete intergation with the existing mirror
touch .installed 
