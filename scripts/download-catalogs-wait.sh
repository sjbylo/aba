#!/bin/bash
# Wait for operator catalog downloads to complete (blocking)
# Used by mirror/Makefile 'catalogs-wait' target

set -eo pipefail

# Scripts called from mirror/Makefile should cd to mirror/
cd "$(dirname "$0")/../mirror" || exit 1

source scripts/include_all.sh

# Get OCP version from aba.conf
source <(normalize-aba-conf)
verify-aba-conf || aba_abort "aba.conf validation failed"

# Extract major.minor version (e.g., 4.20.8 -> 4.20)
ocp_ver_short="${ocp_version%.*}"

# Wait for each catalog individually
for catalog in redhat-operator certified-operator community-operator; do
	task_id="catalog:${ocp_ver_short}:${catalog}"
	
	# run_once handles everything: idempotency, waiting, messages
	if run_once -w -m "Waiting for operator index: ${catalog} v${ocp_ver_short} to finish downloading in the background" -i "$task_id"; then
		aba_info_ok "Operator ${catalog} index v${ocp_ver_short} ready at .index/${catalog}-index-v${ocp_ver_short}"
	else
		# Get error details from the failed task
		error_output=$(run_once -e -i "$task_id" | head -20)
		aba_abort "Failed to download ${catalog} catalog for OCP ${ocp_ver_short}" \
			"Error details from download task:" \
			"$error_output"
	fi
done

aba_info_ok "All operator catalogs ready for OCP $ocp_ver_short"
