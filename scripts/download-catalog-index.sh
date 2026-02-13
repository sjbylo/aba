#!/bin/bash
# Simple catalog downloader - designed to work with run_once
# No background logic, no internal locking, no daemonization
# All orchestration handled by run_once
#
# Usage: download-catalog-index.sh <catalog_name> <version_short>
# Example: download-catalog-index.sh redhat-operator 4.21
#
# Both parameters are required. The caller is responsible for determining
# the version (e.g. from aba.conf or from the release graph for prefetch).

# Derive aba root from script location (this script is in scripts/)
# Use pwd -P to resolve symlinks (important when called via mirror/scripts/ symlink)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
cd "$SCRIPT_DIR/.." || exit 1

source scripts/include_all.sh

# Parse required parameters
catalog_name="${1:?Usage: $0 <catalog_name> <version_short>}"
ocp_ver_major="${2:?Usage: $0 <catalog_name> <version_short>}"

aba_debug "Catalog: $catalog_name, version: $ocp_ver_major"

# Prepare container auth
aba_debug "Creating container auth file"
scripts/create-containers-auth.sh >/dev/null

# Setup paths - must be run from aba root directory
# (download_all_catalogs in include_all.sh ensures CWD is correct)
mkdir -p mirror/.index
index_file="mirror/.index/${catalog_name}-index-v${ocp_ver_major}"
done_file="mirror/.index/.${catalog_name}-index-v${ocp_ver_major}.done"

aba_debug "Index file: $index_file"
aba_debug "Done file: $done_file"

# Cleanup on interrupt
handle_interrupt() {
	echo_red "Aborting catalog download for $catalog_name"
	[ ! -f "$done_file" ] && rm -f "$index_file" "$done_file"
	exit 1
}
trap 'handle_interrupt' INT TERM

# Check if already downloaded
if [[ -s "$index_file" && -f "$done_file" ]]; then
	aba_debug "Index already exists and is complete"
	aba_info "Operator index $catalog_name v$ocp_ver_major already downloaded"
	exit 0
fi
aba_debug "Index not found or incomplete - starting download"

# Check connectivity to registry
aba_debug "Checking connectivity to registry.redhat.io"
if ! curl --connect-timeout 15 --retry 8 -IL http://registry.redhat.io/v2 >/dev/null 2>&1; then
	aba_abort "Cannot access registry.redhat.io - check internet connection"
fi

# Ensure /tmp has enough space on Fedora (oc-mirror uses /tmp)
if grep -qi '^ID=fedora' /etc/os-release 2>/dev/null; then
	size=$(df --output=size -BG /tmp 2>/dev/null | tail -1 | tr -dc '0-9')
	if [ -n "$size" ] && (( size < 10 )); then
		aba_debug "Increasing /tmp size to 10G for oc-mirror"
		sudo mount -o remount,size=10G /tmp 2>/dev/null || true
	fi
fi

# Initialize index file
[ ! -f "$index_file" ] && touch "$index_file"
rm -f "$done_file"

# Download
aba_info "Downloading operator $catalog_name index v$ocp_ver_major..."

# Wait for oc-mirror to be available
aba_debug "Ensuring oc-mirror is downloaded"
if ! ensure_oc_mirror; then
	error_msg=$(get_task_error "$TASK_OC_MIRROR")
	aba_abort "Failed to install oc-mirror:\n$error_msg"
fi

# Fetch catalog using oc-mirror
catalog_url="registry.redhat.io/redhat/${catalog_name}-index:v${ocp_ver_major}"
aba_debug "catalog_url=$catalog_url"
aba_info "Running: oc-mirror list operators --catalog $catalog_url"

# awk '/^NAME/{flag=1; next} flag'  => only used to skip over any unwanted header message
aba_debug "Executing oc-mirror list operators"
oc-mirror list operators --catalog "$catalog_url" | awk '/^NAME/{flag=1; next} flag'  > "$index_file"
ret=$?
aba_debug "oc-mirror exit code: $ret"

# Check both exit code AND output file (oc-mirror v2 sometimes returns 0 even on failure)
if [ $ret -ne 0 ]; then
	aba_abort "oc-mirror list operators failed with exit code $ret for catalog $catalog_name"
elif [ ! -s "$index_file" ]; then
	aba_abort "oc-mirror returned success (exit 0) but output file is empty for $catalog_name"
fi

# Mark completion
aba_debug "Marking download as complete"
touch "$done_file"
aba_info_ok "Downloaded $catalog_name index v$ocp_ver_major successfully"

# Generate helper YAML file (in mirror/ dir for consistency with other files)
yaml_file="mirror/imageset-config-${catalog_name}-catalog-v${ocp_ver_major}.yaml"
aba_debug "Generating helper YAML: $yaml_file"

#tail -n +3 "$index_file" | awk '{print $1,$NF}' | while read op_name op_default_channel; do
cat "$index_file" | awk '{print $1,$NF}' | while read op_name op_default_channel; do
	echo "    - name: $op_name"
	echo "      channels:"
	echo "      - name: \"$op_default_channel\""
done > "$yaml_file"

aba_info "Generated $yaml_file for reference"

exit 0

