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

# Read mirror.conf for ocp_upgrade_to (if set)
[ -s mirror.conf ] && source <(normalize-mirror-conf)

# OKD without operators has no catalog to download
if [ "$(dist_of)" = "okd" ] && [ -z "${ops:-}" ] && [ -z "${op_sets:-}" ]; then
	aba_debug "No operators selected: skipping operator catalog downloads"
	exit 0
fi

# Build version list (current + target if cross-minor upgrade)
read -ra _versions <<< "$(_catalog_versions_to_mirror)"

# OKD: refuse operators that only exist in catalogs needing a Red Hat account
dist_catalog_reject_blocked_ops "${_versions[@]}"

# No internet — nothing to download (e.g. disconnected bastion)
if ! check_internet_connectivity aba quiet 2>/dev/null; then
	exit 0
fi

# Start downloads in parallel (non-blocking, TTL from ~/.aba/config)
for _ver in "${_versions[@]}"; do
	download_all_catalogs "$_ver"
done

# Only announce if downloads are actually running (not already cached)
_any_running=
for _ver in "${_versions[@]}"; do
	for catalog in $(dist_catalogs); do
		if ! run_once -p -i "catalog:${_ver}:${catalog}"; then
			_any_running=1
			break 2
		fi
	done
done

if [ -n "$_any_running" ]; then
	aba_info "Downloading operator catalogs for OCP ${_versions[*]} in background..."
fi

