#!/bin/bash
# Pre-fetch operator catalogs for the two most likely OCP versions
# (stable:latest and previous minor). Run in background at TUI startup
# to reduce wait at operator screen.

source ./scripts/include_all.sh

# Wait for dependencies (both already running in background, so this is
# effectively parallel — total wait is max of the two, not the sum)
run_once -q -w -i "$TASK_OC_MIRROR"
run_once -q -w -S -i "ocp:stable:latest_version"

# Get the latest version (fast — graph data already cached by the version fetch)
stable_latest=$(fetch_latest_version stable)
[[ -z "$stable_latest" ]] && exit 0

version_short="${stable_latest%.*}"  # e.g. 4.21.0 -> 4.21
aba_debug "Pre-fetch: stable:latest=$stable_latest (minor: $version_short)"

# Start catalog downloads for latest minor
download_all_catalogs "$version_short" 86400

# Also pre-fetch catalogs for the previous minor (e.g. 4.21 -> 4.20)
# Users often pick the previous stable version
major="${version_short%%.*}"          # e.g. 4.21 -> 4
minor="${version_short##*.}"          # e.g. 4.21 -> 21
if [[ "$minor" -gt 0 ]]; then
	prev_short="${major}.$(( minor - 1 ))"  # e.g. 4.20
	aba_debug "Pre-fetch: previous minor=$prev_short"
	download_all_catalogs "$prev_short" 86400
fi
