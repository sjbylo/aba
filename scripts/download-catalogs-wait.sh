#!/bin/bash
# Wait for operator catalog downloads to complete (blocking)
# Used by mirror/Makefile 'catalogs-wait' target

set -eo pipefail

# Derive aba root from script location (this script is in scripts/)
cd "$(dirname "$0")/.." || exit 1

source scripts/include_all.sh

# Get OCP version from aba.conf
source <(normalize-aba-conf)
verify-aba-conf || aba_abort "aba.conf validation failed"

# Extract major.minor version (e.g., 4.20.8 -> 4.20)
ocp_ver_short="${ocp_version%.*}"

# Wait for each catalog individually and show detailed status
for catalog in redhat-operator certified-operator community-operator; do
	index_file="mirror/.index/${catalog}-index-v${ocp_ver_short}"
	
	# Check if already downloaded
	if [[ -f "$index_file" && -s "$index_file" ]]; then
		aba_info "Operator index: ${catalog} v${ocp_ver_short} already downloaded to file mirror/.index/${catalog}-index-v${ocp_ver_short}"
		continue
	fi
	
	# Get process ID if task is running
	task_id="catalog:${ocp_ver_short}:${catalog}"
	pid_file="$HOME/.aba/runner/${task_id}.pid"
	
	if [[ -f "$pid_file" ]]; then
		pid=$(<"$pid_file")
		aba_info "Waiting for operator index: ${catalog} v${ocp_ver_short} to finish downloading in the background (process id = ${pid}) ..."
	else
		aba_info "Waiting for operator index: ${catalog} v${ocp_ver_short} ..."
	fi
	
	# Wait for this catalog
	if run_once -w -i "$task_id"; then
		aba_info "Operator ${catalog} index v${ocp_ver_short} download to file mirror/.index/${catalog}-index-v${ocp_ver_short} has completed"
	else
		aba_abort "Failed to download ${catalog} catalog for OCP ${ocp_ver_short}"
	fi
done

aba_info_ok "All operator catalogs ready for OCP $ocp_ver_short"

