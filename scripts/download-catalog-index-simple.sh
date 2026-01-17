#!/bin/bash
# Simple catalog downloader - designed to work with run_once
# No background logic, no internal locking, no daemonization
# All orchestration handled by run_once

source scripts/include_all.sh

# Parse catalog name
catalog_name="${1:-redhat-operator}"

aba_debug "Starting simple catalog download for: $catalog_name"

# Validate config
source <(normalize-aba-conf)
verify-aba-conf || exit 1

if [ -z "$ocp_version" ]; then
	aba_abort "Error: ocp_version not defined in aba.conf"
fi

ocp_ver="$ocp_version"
ocp_ver_major=$(echo "$ocp_version" | cut -d. -f1-2)

aba_debug "OCP version: $ocp_ver (major: $ocp_ver_major)"

# Prepare container auth
scripts/create-containers-auth.sh >/dev/null

# Setup paths using absolute paths (no need to cd)
mkdir -p "$ABA_ROOT/mirror/.index"
index_file="$ABA_ROOT/mirror/.index/${catalog_name}-index-v${ocp_ver_major}"
done_file="$ABA_ROOT/mirror/.index/.${catalog_name}-index-v${ocp_ver_major}.done"

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
	aba_info "Operator index $catalog_name v$ocp_ver_major already downloaded"
	exit 0
fi

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
run_once -w -i cli:install:oc-mirror -- make -sC cli oc-mirror

# Fetch catalog using oc-mirror
catalog_url="registry.redhat.io/redhat/${catalog_name}-index:v${ocp_ver_major}"
aba_info "Running: oc-mirror list operators --catalog $catalog_url"

if ! oc-mirror list operators --catalog "$catalog_url" > "$index_file"; then
	ret=$?
	aba_abort "oc-mirror failed with exit code $ret for catalog $catalog_name"
fi

# Verify we got data
if [ ! -s "$index_file" ]; then
	aba_abort "Downloaded index file is empty for $catalog_name"
fi

# Mark completion
touch "$done_file"
aba_info_ok "Downloaded $catalog_name index v$ocp_ver_major successfully"

# Generate helper YAML file (in mirror/ dir for consistency with other files)
yaml_file="$ABA_ROOT/mirror/imageset-config-${catalog_name}-catalog-v${ocp_ver_major}.yaml"
aba_debug "Generating helper YAML: $yaml_file"

tail -n +3 "$index_file" | awk '{print $1,$NF}' | while read op_name op_default_channel; do
	echo "    - name: $op_name"
	echo "      channels:"
	echo "      - name: \"$op_default_channel\""
done > "$yaml_file"

aba_info "Generated $yaml_file for reference"

exit 0

