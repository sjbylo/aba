#!/bin/bash
# Pre-fetch operator catalog indices for the two most likely OCP versions
# (stable:latest and previous minor). Run in background at TUI startup
# to reduce wait at operator screen.
#
# Uses download_all_catalogs (which uses run_once) so the wizard sees
# the same task IDs and skips re-downloading.
# If anything fails, exit silently — the real download handles it later.

source ./scripts/include_all.sh

# Wait for oc-mirror (already downloading in background)
run_once -q -w -i "$TASK_OC_MIRROR" || exit 0

# Container auth for registry.redhat.io
scripts/create-containers-auth.sh >/dev/null 2>&1 || exit 0

# Wait for version data (already fetching in background)
run_once -q -w -S -i "ocp:stable:latest_version" 2>/dev/null || exit 0

# Get latest stable version from cached graph data
stable_latest=$(fetch_latest_version stable 2>/dev/null) || exit 0
[[ -z "$stable_latest" ]] && exit 0

version_short="${stable_latest%.*}"  # e.g. 4.21.0 -> 4.21
aba_debug "Pre-fetch: stable:latest=$stable_latest (minor: $version_short)"

# Download catalogs for latest minor first
download_all_catalogs "$version_short" 86400

# Wait for latest to complete before starting previous (avoid 6 concurrent downloads)
wait_for_all_catalogs "$version_short" || exit 0

# Then pre-fetch for the previous minor (e.g. 4.21 -> 4.20)
major="${version_short%%.*}"          # e.g. 4
minor="${version_short##*.}"          # e.g. 21
if (( minor > 0 )); then
	prev_short="${major}.$(( minor - 1 ))"  # e.g. 4.20
	aba_debug "Pre-fetch: previous minor=$prev_short"
	download_all_catalogs "$prev_short" 86400
fi
