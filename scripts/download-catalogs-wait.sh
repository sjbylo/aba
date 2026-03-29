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

# Wait for each catalog individually
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
