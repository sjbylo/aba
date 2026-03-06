#!/bin/bash
# Register an existing (externally-managed) mirror registry with ABA.
# Copies the user-provided pull secret and CA cert into the regcreds dir,
# trusts the CA system-wide, writes state.sh with REG_VENDOR=existing,
# and marks the mirror as .installed.
#
# Usage (called via mirror/Makefile register target):
#   scripts/reg-register.sh <pull_secret_file> <ca_cert_file>

[ -z "${INFO_ABA+x}" ] && export INFO_ABA=1

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

source <(normalize-aba-conf)
source <(normalize-mirror-conf)
export regcreds_dir=$HOME/.aba/mirror/$(basename "$PWD")

pull_secret_file="$1"
ca_cert_file="$2"

[ ! -f "$pull_secret_file" ] && aba_abort "Pull secret file not found: $pull_secret_file"
[ ! -f "$ca_cert_file" ] && aba_abort "CA cert file not found: $ca_cert_file"

if [ ! "$reg_host" -o ! "$reg_port" ]; then
	aba_abort "reg_host and reg_port must be set in mirror.conf before registering." \
		"Run: aba -d $(basename $PWD) --reg-host <hostname> first."
fi

# Back up existing regcreds if present
if [ -d "$regcreds_dir" ]; then
	rm -rf "${regcreds_dir}.bk"
	mv "$regcreds_dir" "${regcreds_dir}.bk"
fi
mkdir -p "$regcreds_dir"

# Copy pull secret as-is
aba_info "Copying pull secret to $regcreds_dir/pull-secret-mirror.json"
cp "$pull_secret_file" "$regcreds_dir/pull-secret-mirror.json"
chmod 600 "$regcreds_dir/pull-secret-mirror.json"

# Copy CA cert
aba_info "Copying CA cert to $regcreds_dir/rootCA.pem"
cp "$ca_cert_file" "$regcreds_dir/rootCA.pem"
chmod 644 "$regcreds_dir/rootCA.pem"

# Trust the CA system-wide
trust_root_ca "$regcreds_dir/rootCA.pem"

# Write state.sh marking this as an externally-managed registry
cat > "$regcreds_dir/state.sh" <<-EOF
REG_VENDOR=existing
REG_HOST=$reg_host
REG_PORT=$reg_port
REG_INSTALLED_AT="$(date '+%Y-%m-%d %H:%M:%S')"
EOF
aba_info "Saved registry state to $regcreds_dir/state.sh"

echo
aba_info_ok "Existing registry registered: $reg_host:$reg_port"
aba_info "Credentials stored in: $regcreds_dir/"
aba_info "Run 'aba -d $(basename $PWD) verify' to confirm connectivity."
