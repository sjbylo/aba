#!/bin/bash
# Register an existing (externally-managed) mirror registry with ABA.
# Copies the user-provided pull secret and CA cert into the regcreds dir,
# trusts the CA system-wide, writes state.sh with reg_vendor=existing,
# and marks the mirror as .available.
#
# Usage (called via mirror/Makefile register target):
#   scripts/reg-register.sh <pull_secret_file> <ca_cert_file>

[ -z "${INFO_ABA+x}" ] && export INFO_ABA=1

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

source <(normalize-aba-conf)
source <(normalize-mirror-conf)
export regcreds_dir=$HOME/.aba/mirror/$(basename "$PWD")
export regcreds_display="regcreds"

pull_secret_file="$1"
ca_cert_file="$2"

[ ! -f "$pull_secret_file" ] && aba_abort "Pull secret file not found: $pull_secret_file"
[ ! -f "$ca_cert_file" ] && aba_abort "CA cert file not found: $ca_cert_file"

# Guard: abort if ABA already manages an installed registry here.
# Overwriting state from an ABA-installed registry would orphan it (can't uninstall).
if [ -s "$regcreds_dir/state.sh" ]; then
	source "$regcreds_dir/state.sh"
	if [ "${reg_vendor:-}" != "existing" ]; then
		aba_abort "An ABA-managed registry ($reg_vendor) is already installed here." \
			"Run 'aba -d $(basename "$PWD") uninstall' first, then register."
	else
		aba_warn "Re-registering: overwriting previous external registry state ($reg_host:$reg_port)."
	fi
fi

# --- Reconcile reg_host:reg_port with the pull secret's .auths entries ---
# The pull secret is the source of truth for "which hostname has these credentials".
# ABA must ensure mirror.conf's reg_host:reg_port matches what the pull secret provides,
# otherwise downstream commands (verify, sync, install) will fail to authenticate.
_ps_keys=$(jq -r '.auths | keys[]' "$pull_secret_file" 2>/dev/null)
_ps_count=$(echo "$_ps_keys" | wc -l)

if [ -z "$_ps_keys" ]; then
	aba_abort "Pull secret has no entries in .auths -- cannot determine registry hostname."
fi

if [ "$reg_host" ] && [ "$reg_port" ]; then
	# mirror.conf has a hostname (from --reg-host or template default).
	# Validate it exists in the pull secret -- catch mismatches early rather than
	# failing later with cryptic auth errors or hangs (Bug #396).
	if ! jq -e ".auths[\"$reg_host:$reg_port\"]" "$pull_secret_file" >/dev/null 2>&1; then
		if [ "$_ps_count" -eq 1 ]; then
			# Unambiguous: pull secret has exactly one entry. Use it.
			# Common case: template defaulted to one name, pull secret was generated
			# for the registry's canonical hostname. Both point to the same registry.
			if [[ "$_ps_keys" == *:* ]]; then
				_inferred_host="${_ps_keys%%:*}"          # host from "host:port"
				_inferred_port="${_ps_keys##*:}"          # port from "host:port"
			else
				_inferred_host="$_ps_keys"
				_inferred_port="443"
			fi
			aba_info "Pull secret is keyed to '$_ps_keys' (mirror.conf had '$reg_host:$reg_port')."
			aba_info "Updating mirror.conf to match pull secret."
			sed -i "s/^reg_host=.*/reg_host=$_inferred_host/" mirror.conf
			sed -i "s/^reg_port=.*/reg_port=$_inferred_port/" mirror.conf
			reg_host="$_inferred_host"
			reg_port="$_inferred_port"
		else
			# Ambiguous: multiple entries, none match. User must disambiguate.
			aba_abort "Pull secret has no entry for '$reg_host:$reg_port'." \
				"Available entries:" \
				"$_ps_keys" \
				"Use --reg-host matching one of the above, or regenerate with: aba -d $(basename $PWD) password"
		fi
	fi
elif [ "$_ps_count" -eq 1 ]; then
	# No reg_host/reg_port in mirror.conf at all -- infer from the single pull secret entry.
	if [[ "$_ps_keys" == *:* ]]; then
		reg_host="${_ps_keys%%:*}"                        # host from "host:port"
		reg_port="${_ps_keys##*:}"                        # port from "host:port"
	else
		reg_host="$_ps_keys"
		reg_port="443"
	fi
	sed -i "s/^reg_host=.*/reg_host=$reg_host/" mirror.conf
	sed -i "s/^reg_port=.*/reg_port=$reg_port/" mirror.conf
	aba_info "Inferred reg_host=$reg_host reg_port=$reg_port (from pull secret)"
else
	aba_abort "reg_host and reg_port must be set in mirror.conf before registering." \
		"Pull secret has multiple entries: $_ps_keys" \
		"Run: aba -d $(basename $PWD) --reg-host <hostname> first."
fi

# Back up existing regcreds if present
if [ -d "$regcreds_dir" ]; then
	rm -rf "${regcreds_dir}.bk"
	mv "$regcreds_dir" "${regcreds_dir}.bk"
fi
mkdir -p "$regcreds_dir"

# Copy pull secret (validated above to contain reg_host:reg_port)
aba_info "Copying pull secret to $regcreds_display/pull-secret-mirror.json"
cp "$pull_secret_file" "$regcreds_dir/pull-secret-mirror.json"
chmod 600 "$regcreds_dir/pull-secret-mirror.json"

# Copy CA cert
aba_info "Copying CA cert to $regcreds_display/rootCA.pem"
cp "$ca_cert_file" "$regcreds_dir/rootCA.pem"
chmod 644 "$regcreds_dir/rootCA.pem"

# Trust the CA system-wide
trust_root_ca "$regcreds_dir/rootCA.pem"

# Write state.sh marking this as an externally-managed registry
cat > "$regcreds_dir/state.sh" <<-EOF
reg_vendor=existing
reg_host=$reg_host
reg_port=$reg_port
last_action=register
last_action_at='$(date '+%Y-%m-%d %H:%M:%S')'
reg_installed_at='$(date '+%Y-%m-%d %H:%M:%S')'
EOF
aba_info "Saved registry state to $regcreds_display/state.sh"

echo
aba_success "Existing registry registered: $reg_host:$reg_port"
aba_info "Credentials stored in: $regcreds_display/"
aba_info "Run 'aba -d $(basename $PWD) verify' to confirm connectivity."
