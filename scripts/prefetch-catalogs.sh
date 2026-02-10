#!/bin/bash
# Pre-fetch operator catalogs for the most likely OCP version (stable:latest).
# Run this in the background at TUI startup to reduce wait at operator screen.

source ./scripts/include_all.sh

# Wait for dependencies (both already running in background, so this is
# effectively parallel — total wait is max of the two, not the sum)
run_once -q -w -i "$TASK_OC_MIRROR"
run_once -q -w -S -i "ocp:stable:latest_version"

# Get the version (fast — graph data already cached by the version fetch)
stable_latest=$(fetch_latest_version stable)
[[ -z "$stable_latest" ]] && exit 0

version_short="${stable_latest%.*}"  # e.g. 4.20.8 -> 4.20
aba_debug "Pre-fetch: stable=$stable_latest (minor: $version_short)"

# Start catalog downloads (run_once backgrounds each one)
download_all_catalogs "$version_short" 86400
