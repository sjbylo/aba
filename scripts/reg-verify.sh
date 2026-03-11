#!/bin/bash 
# Try to verify access to the registry, as defined in mirror.conf

# Enable INFO messages by default when called directly from make
# (unless explicitly disabled by parent process via --quiet)
[ -z "${INFO_ABA+x}" ] && export INFO_ABA=1

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

umask 077

#source <(normalize-aba-conf)
source <(normalize-mirror-conf)
export regcreds_dir=$HOME/.aba/mirror/$(basename "$PWD")

verify-mirror-conf || aba_abort "Invalid or incomplete mirror.conf. Check the errors above and fix mirror/mirror.conf."

if [ ! "$reg_host" -o ! "$reg_port" ]; then
	aba_abort "No registry is configured in: mirror/mirror.conf.  Run: 'aba -d mirror mirror.conf' and edit the mirror.conf file."
fi

reg_url=https://$reg_host:$reg_port

# Check for existing reg. creds
if [ ! -s "$regcreds_dir/pull-secret-mirror.json" ]; then
	aba_abort \
		"No mirror registry credentials found for host: $reg_host" \
		"You have two options:" \
		"- To install a new registry:  aba -d $(basename "$PWD") install" \
		"- To use an existing registry: aba -d $(basename "$PWD") register --pull-secret-mirror <file> --ca-cert <file>" \
		"See 'aba mirror --help' or the README.md for more."
fi

if [ -s "$regcreds_dir/rootCA.pem" ]; then
	# Check if the cert needs to be updated
	trust_root_ca "$regcreds_dir/rootCA.pem"
else
	aba_abort \
		"Mirror registry pull secret file 'pull-secret-mirror.json' found in regcreds/ but no 'rootCA.pem' cert file found." \
		"Either copy your registry's root CA file into regcreds/rootCA.pem," \
		"or re-register with: aba -d $(basename "$PWD") register --pull-secret-mirror <file> --ca-cert <file>"
fi

# Check valid config in mirror.conf
mirrors=$(jq -r '.auths | keys[]' "$regcreds_dir/pull-secret-mirror.json")
if ! echo "$mirrors" | grep -q "^$reg_host:$reg_port$"; then
	aba_warning \
		"Values in mirror.conf do not match the values in pull secret: regcreds/pull-secret-mirror.json!" \
		"Value in mirror.conf: $reg_host:$reg_port" \
		"Value in pull-secret-mirror.json: $(echo $mirrors | tr '\n' ' ')" \
		"Mirror authentication/verification may fail.  Fix the issue and try again!"
	sleep 1
fi
# FIXME: Could do more here and check the actual cert content matches as well. 

# Test registry access with podman 
aba_info "Checking registry access is working using podman login:"
podman logout --all #>/dev/null 
cmd="podman login --authfile $regcreds_dir/pull-secret-mirror.json $reg_url"
aba_info "Running: $cmd"
$cmd

aba_info_ok "Success! Valid registry credential file(s) found in regcreds/ for registry $reg_url"

exit 0

