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

aba_info "Starting operator catalog downloads for OCP $ocp_ver_short (background)"
aba_info "  • redhat-operator"
aba_info "  • certified-operator"
aba_info "  • community-operator"

# Catalog downloads need oc-mirror; ensure it's at least downloading
ensure_oc_mirror || aba_debug "Warning: oc-mirror not yet available, catalogs may retry"

# Start downloads in parallel (non-blocking, 1-day TTL)
download_all_catalogs "$ocp_ver_short" 86400

# Peek at task status: only show "in background" if downloads are actually running
_any_running=
for catalog in redhat-operator certified-operator community-operator; do
	if ! run_once -p -i "catalog:${ocp_ver_short}:${catalog}"; then
		_any_running=1
		break
	fi
done

if [ -n "$_any_running" ]; then
	aba_info "Catalog downloads running in background. This may take a while to complete."
	aba_info "Run 'aba save' / 'aba sync' to continue (which waits automatically)."
else
	aba_info_ok "All operator catalogs already available for OCP $ocp_ver_short."
fi

