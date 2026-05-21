#!/bin/bash
# Wait for operator catalog downloads to complete (blocking)
# Used by mirror/Makefile 'catalogs-wait' target

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

# Populate .index/ from shipped catalogs if live versions don't exist yet
_populate_shipped_indexes

# If all 3 catalog indexes already exist (shipped or previously downloaded),
# kick off background refreshes but don't block.
_have_all=true
for catalog in redhat-operator certified-operator community-operator; do
	[[ -s ".index/${catalog}-index-v${ocp_ver_short}" ]] || { _have_all=false; break; }
done

if [[ "$_have_all" == true ]]; then
	# Start downloads for freshness (no-op if already running)
	download_all_catalogs "$ocp_ver_short" >/dev/null 2>&1 || true
	aba_info_ok "All operator catalogs ready for OCP $ocp_ver_short"
	exit 0
fi

# Wait: catalogs started by download_all_catalogs() in include_all.sh
for catalog in redhat-operator certified-operator community-operator; do
	task_id="catalog:${ocp_ver_short}:${catalog}"

	if ! run_once -w -m "Waiting for ${catalog} catalog v${ocp_ver_short}" -i "$task_id"; then
		error_output=$(run_once -e -i "$task_id" | head -20)
		aba_abort "Failed to download ${catalog} catalog for OCP ${ocp_ver_short}" \
			"Error details from download task:" \
			"$error_output"
	fi
done

aba_info_ok "All operator catalogs ready for OCP $ocp_ver_short"
