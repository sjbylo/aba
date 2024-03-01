#!/bin/bash -e

source scripts/include_all.sh

[ "$1" ] && set -x

source <(normalize-aba-conf)
source <(normalize-mirror-conf)

read -p "Enter username [init]: " reg_user
[ ! "$reg_user" ] && reg_user=init 

read -sp "Enter password: " reg_pw
echo

export enc_password=$(echo -n "$reg_user:$reg_pw" | base64 -w0)

# Inputs: enc_password, reg_host and reg_port 
scripts/j2 ./templates/pull-secret-mirror.json.j2 > ./regcreds/pull-secret-mirror.json

# Note that for https, the installation of OCP *will* require the registry's root certificate 
podman logout --all >/dev/null
podman login --tls-verify=false --authfile=regcreds/pull-secret-mirror.json  $reg_host:$reg_port

# Add flag so 'make install' is complete
touch .installed 
