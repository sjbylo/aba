#!/bin/bash
# Find the available pull secrets and place them in the right locations: ~/.docker ~/.containers

set -eo pipefail

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

public_pull_secret_file_needed=1  # Only needed for 'save' and 'sync'
[ "$1" = "--load" ] && public_pull_secret_file_needed= && shift

umask 077

source <(normalize-aba-conf)
# $regcreds_dir is derived by mirror-side callers from $PWD, or by cluster-side callers from image_source in cluster.conf.

# Default regcreds_dir if caller didn't set it — prevents the Red Hat-only fallback
# from silently overwriting ~/.docker/config.json and destroying mirror credentials.
if [[ -z "${regcreds_dir:-}" ]]; then
	export regcreds_dir=$HOME/.aba/mirror/mirror
	export regcreds_display="${regcreds_display:-mirror/regcreds}"
	aba_debug "regcreds_dir was unset, defaulting to $regcreds_dir"
fi

verify-aba-conf || aba_abort "$_ABA_CONF_ERR"

# auths is a map keyed by registry host. The pull secret replaces that host
# and leaves every other host and every other top-level key. Merging the same
# secret again does not add entries.
merge_container_auth() {
	local src="$1" dest="$2" tmp
	mkdir -p "$(dirname "$dest")"
	if [ ! -s "$dest" ]; then
		cp "$src" "$dest"
		return 0
	fi
	tmp=$(mktemp "$(dirname "$dest")/.auth.XXXXXX")
	if ! jq -s '.[0] * .[1]' "$dest" "$src" > "$tmp"; then
		rm -f "$tmp"
		aba_abort "Failed to merge container auth into $dest"
	fi
	mv "$tmp" "$dest"
}

if [ "$public_pull_secret_file_needed" ] && [ ! -s "$pull_secret_file" ]; then
	if [ ! "$pull_secret_file" ]; then
		aba_abort "pull_secret_file not defined in aba.conf"
	fi

	aba_abort \
		"Error: Your pull secret file '$pull_secret_file' does not exist!" \
		"Download it from https://console.redhat.com/openshift/downloads#tool-pull-secret (select 'Tokens' in the pull-down)"
fi

aba_debug "Ensuring dirs exist: ~/.docker ~/.containers $XDG_RUNTIME_DIR/containers"
mkdir -p ~/.docker ~/.containers
[[ "$XDG_RUNTIME_DIR" == /* ]] && mkdir -p "$XDG_RUNTIME_DIR/containers"

# Pick the best available auth source:
#   mirror + Red Hat → merge both into a combined file
#   mirror only      → use mirror creds
#   Red Hat only     → use Red Hat pull secret
if [ -s "$regcreds_dir/pull-secret-mirror.json" ] && [ -s "$pull_secret_file" ]; then
	jq -s '.[0] * .[1]' "$regcreds_dir/pull-secret-mirror.json" "$pull_secret_file" > "$regcreds_dir/pull-secret-full.json"
	_auth_src="$regcreds_dir/pull-secret-full.json"
elif [ -s "$regcreds_dir/pull-secret-mirror.json" ]; then
	_auth_src="$regcreds_dir/pull-secret-mirror.json"
elif [ -s "$pull_secret_file" ]; then
	_auth_src="$pull_secret_file"
else
	aba_abort "Pull secret file(s) missing: '$pull_secret_file', '${regcreds_display:-regcreds}/pull-secret-mirror.json' and/or '${regcreds_display:-regcreds}/pull-secret-full.json'"
fi

aba_debug "Merging $_auth_src into ~/.docker/config.json and ~/.containers/auth.json"
merge_container_auth "$_auth_src" ~/.docker/config.json
merge_container_auth "$_auth_src" ~/.containers/auth.json
if [[ "$XDG_RUNTIME_DIR" == /* ]]; then
	aba_debug "Merging $_auth_src into $XDG_RUNTIME_DIR/containers/auth.json"
	merge_container_auth "$_auth_src" "$XDG_RUNTIME_DIR/containers/auth.json" || true
fi
