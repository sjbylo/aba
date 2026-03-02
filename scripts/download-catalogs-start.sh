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
verify-aba-conf || aba_abort "Invalid or incomplete aba.conf. Check the errors above and fix aba.conf."

# Extract major.minor version (e.g., 4.20.8 -> 4.20)
ocp_ver_short="${ocp_version%.*}"

aba_info "Starting operator catalog downloads for OCP $ocp_ver_short (background)"
aba_info "  • redhat-operator"
aba_info "  • certified-operator"
aba_info "  • community-operator"

# Start downloads in parallel (non-blocking, 1-day TTL)
download_all_catalogs "$ocp_ver_short" 86400

aba_debug "Catalog download tasks started in background"

