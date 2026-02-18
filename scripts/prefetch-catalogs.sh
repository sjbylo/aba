#!/bin/bash
# Pre-fetch operator catalog indices for the two most likely OCP versions.
# Run in background at TUI startup to reduce wait at operator screen.
#
# Version resolution (no channel dependency -- catalogs are per minor version):
#   1. If aba.conf exists and has ocp_version (e.g. 4.20.13) -> use 4.20
#   2. Otherwise wait for stable:latest version fetch -> use that minor
#
# Downloads catalogs for the resolved version, then for the previous minor.
# Uses download_all_catalogs (which uses run_once) so the wizard sees
# the same task IDs and skips re-downloading.
# If anything fails, exit silently -- the real download handles it later.

source ./scripts/include_all.sh

# Pull secret is required for registry.redhat.io access
if [[ ! -f ~/.pull-secret.json ]]; then
	aba_debug "Pre-fetch: no pull secret found, exiting"
	exit 0
fi

# Wait for oc-mirror (already downloading in background)
run_once -q -w -i "$TASK_OC_MIRROR" || exit 0

# Container auth for registry.redhat.io
scripts/create-containers-auth.sh >/dev/null 2>&1 || exit 0

# Determine OCP minor version to prefetch
version_short=""

if [[ -f aba.conf ]]; then
	# Read ocp_version from existing config (channel-independent)
	_ocp_ver=$(source <(normalize-aba-conf 2>/dev/null) && echo "${ocp_version:-}" 2>/dev/null)
	if [[ -n "$_ocp_ver" && "$_ocp_ver" == *.*.* ]]; then
		version_short="${_ocp_ver%.*}"  # e.g. 4.20.13 -> 4.20
		aba_debug "Pre-fetch: using version from aba.conf: $_ocp_ver (minor: $version_short)"
	fi
fi

if [[ -z "$version_short" ]]; then
	# No aba.conf or no version set -- fall back to stable:latest
	run_once -q -w -S -i "ocp:stable:latest_version" || exit 0
	stable_latest=$(fetch_latest_version stable 2>/dev/null) || exit 0
	[[ -z "$stable_latest" ]] && exit 0
	version_short="${stable_latest%.*}"  # e.g. 4.21.0 -> 4.21
	aba_debug "Pre-fetch: using stable:latest=$stable_latest (minor: $version_short)"
fi

# Download catalogs for the resolved version
download_all_catalogs "$version_short" 86400

# Wait for completion before starting previous (avoid 6 concurrent downloads)
wait_for_all_catalogs "$version_short" || exit 0

# Pre-fetch for the previous minor (e.g. 4.21 -> 4.20)
major="${version_short%%.*}"
minor="${version_short##*.}"
if (( minor > 0 )); then
	prev_short="${major}.$(( minor - 1 ))"
	aba_debug "Pre-fetch: previous minor=$prev_short"
	download_all_catalogs "$prev_short" 86400
fi
