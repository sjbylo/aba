#!/bin/bash
# Simple wrapper to download and wait for all catalog indexes
# Used by mirror/Makefile 'index' target

set -eo pipefail

# Derive aba root from script location (this script is in scripts/)
# Use pwd -P to resolve symlinks (important when called via cluster-dir/scripts/ symlink)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
cd "$SCRIPT_DIR/.." || exit 1

source scripts/include_all.sh

# Get OCP version from aba.conf
source <(normalize-aba-conf)
verify-aba-conf || aba_abort "aba.conf validation failed"

# Extract major.minor version (e.g., 4.20.8 -> 4.20)
ocp_ver_short="${ocp_version%.*}"

aba_info "Downloading operator catalogs for OCP $ocp_ver_short"

# Download all catalogs in parallel (1-day TTL)
download_all_catalogs "$ocp_ver_short" 86400

# Wait for all to complete
wait_for_all_catalogs "$ocp_ver_short"

aba_info_ok "All operator catalogs ready for OCP $ocp_ver_short"

