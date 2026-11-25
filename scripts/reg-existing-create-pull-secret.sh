#!/bin/bash -e
# Create the pull secret for your existing mirror registry.
# Usage: aba -d mirror -H myreg.example.com password 

source scripts/include_all.sh

aba_debug "Starting: $0 $* in $PWD"

source <(normalize-aba-conf)
source <(normalize-mirror-conf)
export regcreds_dir=$HOME/.aba/mirror/$(basename "$PWD")

read -rp "Enter username [init]: " reg_user
[ ! "$reg_user" ] && reg_user=init 

read -rsp "Enter password: " reg_pw
echo

export enc_password=$(echo -n "$reg_user:$reg_pw" | base64 -w0)

mkdir -p "$regcreds_dir"
# Inputs: enc_password, reg_host and reg_port
scripts/j2 ./templates/pull-secret-mirror.json.j2 > "$regcreds_dir/.pull-secret-mirror.json"

# Login writes only --authfile. logout --all would clear every registry in
# the default store, including logins this command did not create.
# Note that for https, the installation of OpenShift *will* require the registry's root certificate
if podman login --tls-verify=false --authfile="$regcreds_dir/.pull-secret-mirror.json"  $reg_host:$reg_port; then
	mv "$regcreds_dir/.pull-secret-mirror.json" "$regcreds_dir/pull-secret-mirror.json"
else
	rm -f "$regcreds_dir/.pull-secret-mirror.json"
fi

[ ! -s "$regcreds_dir/rootCA.pem" ] && \
	aba_warn -p IMPORTANT \
		"Fetch the root CA file for $reg_host and copy it to $regcreds_dir/rootCA.pem.  After the file is in place, run: aba -d mirror verify"

