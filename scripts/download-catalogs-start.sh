#!/bin/bash
# Start operator catalog downloads in background (non-blocking)
# Used by mirror/Makefile 'catalogs-download' target

set -eo pipefail

# CWD is set by mirror/Makefile to the correct mirror directory

# Enable INFO messages by default when called directly from make
# (unless explicitly disabled by parent process via --quiet)
[ -z "${INFO_ABA+x}" ] && export INFO_ABA=1

source scripts/include_all.sh

# Get OCP version from aba.conf
source <(normalize-aba-conf)
verify-aba-conf || aba_abort "$_ABA_CONF_ERR"

# Extract major.minor version (e.g., 4.20.8 -> 4.20)
ocp_ver_short="${ocp_version%.*}"

# Start downloads in parallel (non-blocking, TTL from ~/.aba/config)
download_all_catalogs "$ocp_ver_short"

# Only announce if downloads are actually running (not already cached)
_any_running=
for catalog in redhat-operator certified-operator community-operator; do
	if ! run_once -p -i "catalog:${ocp_ver_short}:${catalog}"; then
		_any_running=1
		break
	fi
done

if [ -n "$_any_running" ]; then
	aba_info "Downloading operator catalogs for OCP $ocp_ver_short in background..."
fi

