#!/bin/bash 
# Try to verify access to the registry, as defined in mirror.conf

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

umask 077

#source <(normalize-aba-conf)
source <(normalize-mirror-conf)

#verify-aba-conf || exit 1
verify-mirror-conf || exit 1

if [ ! "$reg_host" -o ! "$reg_port" ]; then
	aba_abort "No registry is configured in: mirror/mirror.conf.  Run: 'aba -d mirror mirror.conf' and edit the mirror.conf file."
fi

reg_url=https://$reg_host:$reg_port

# Check for existing reg. creds
if [ ! -s regcreds/pull-secret-mirror.json ]; then
	aba_abort \
		"No mirror registry credential file found in: $PWD/regcreds/pull-secret-mirror.json" \
		"You have two options:" \
		"- To install Quay, see: aba mirror --help" \
		"- To use an existing mirror registry, copy its pull secret and root CA files into: $PWD/regcreds/ and try again." \
		"  The files must be named 'regcreds/pull-secret-mirror.json' and 'regcreds/rootCA.pem' respectively." \
		"See the README.md for more."
fi

if [ -s regcreds/rootCA.pem ]; then
	# Check if the cert needs to be updated
	trust_root_ca regcreds/rootCA.pem
else
	aba_abort \
		"Mirror registry pull secret file 'pull-secret-mirror.json' found in 'regcreds/' but no 'rootCA.pem' cert file found." \
		"CA file missing: rootCA.pem.  Copy your registry's root CA file into 'regcreds/rootCA.pem' and try again."
fi

# Check valid config in mirror.conf
mirrors=$(jq -r '.auths | keys[]' regcreds/pull-secret-mirror.json)
if ! echo "$mirrors" | grep -q "^$reg_host:$reg_port$"; then
	aba_warning \
		"Values in aba/mirror/mirror.conf do not match the values in pull secret: mirror/regcreds/pull-secret-mirror.json!" \
		"Value in mirror.conf: $reg_host:$reg_port" \
		"Value in pull-secret-mirror.json: $(echo $mirrors | tr '\n' ' ')" \
		"Mirror authentication/verification may fail.  Fix the issue and try again!"
	sleep 1
fi
# FIXME: Could do more here and check the actual cert content matches as well. 

# Test registry access with podman 
aba_info "Checking registry access is working using podman login:"
podman logout --all #>/dev/null 
cmd="podman login --authfile regcreds/pull-secret-mirror.json $reg_url"
aba_info "Running: $cmd"
$cmd

aba_info_ok "Success! Valid registry credential file(s) found in mirror/regcreds/ for registry $reg_url"

exit 0

