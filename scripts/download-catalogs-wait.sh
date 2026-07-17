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

# Read mirror.conf for ocp_upgrade_to (if set)
[ -s mirror.conf ] && source <(normalize-mirror-conf)

# Build version list (current + target if cross-minor upgrade)
read -ra _versions_to_wait <<< "$(_catalog_versions_to_mirror)"

# Populate .index/ from shipped catalogs if live versions don't exist yet
_populate_shipped_indexes

# If all catalog indexes already exist (shipped or previously downloaded),
# kick off background refreshes but don't block.
_have_all=true
for _ver in "${_versions_to_wait[@]}"; do
	for catalog in redhat-operator certified-operator community-operator; do
		[[ -s ".index/${catalog}-index-v${_ver}" ]] || { _have_all=false; break 2; }
	done
done

if [[ "$_have_all" == true ]]; then
	for _ver in "${_versions_to_wait[@]}"; do
		download_all_catalogs "$_ver" >/dev/null 2>&1 || true
	done
fi

# Wait: catalogs started by download_all_catalogs() in include_all.sh
# Skip run_once validation when all catalog files already exist -- validation
# re-runs the full download command (podman pull + extract), adding ~40s overhead.
# When files are missing (_have_all=false), validation still runs and self-heals.
_skip_val=""
[[ "$_have_all" == true ]] && _skip_val="-S"

for _ver in "${_versions_to_wait[@]}"; do
	for catalog in redhat-operator certified-operator community-operator; do
		task_id="catalog:${_ver}:${catalog}"

		if ! run_once $_skip_val -w -m "Waiting for ${catalog} catalog v${_ver}" -i "$task_id"; then
			error_output=$(run_once -e -i "$task_id" | head -20)
			aba_abort "Failed to download ${catalog} catalog for OCP ${_ver}" \
				"Error details from download task:" \
				"$error_output"
		fi
	done
done

aba_success "All operator catalogs ready for OCP ${_versions_to_wait[*]}"
