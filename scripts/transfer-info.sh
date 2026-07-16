#!/bin/bash
# transfer-info.sh -- Inspect the pending aba-transfer.tar and report its contents
#
# INTENT:    Show what an 'aba load' will actually load: OCP version, channel,
#            upgrade target, and operator list. Reads from the transfer tar
#            (if present) so the displayed info matches the transferred content,
#            not the local config which may be stale.
# CALLED BY: make -C mirror transfer-info, aba transfer-info, TUI (--shell mode)
# CWD:       mirror/ directory
# REQUIRES:  tar, grep, sed
# PRODUCES:  Human-readable summary (default) or sourceable key=value (--shell)
# SIDE EFFECTS: None (read-only; temp files cleaned up)
# IDEMPOTENT: Yes

set -eo pipefail

_shell_mode=false
for arg in "$@"; do
	case "$arg" in
		shell|--shell) _shell_mode=true ;;
	esac
done

_transfer_tar="data/aba-transfer.tar"
_isc_file="data/imageset-config.yaml"
_meta_file="data/aba-transfer-metadata.json"
_tmpdir=""

_cleanup_tmp() {
	if [[ -n "$_tmpdir" ]]; then
		rm -rf "$_tmpdir"
	fi
}
trap _cleanup_tmp EXIT

# If a transfer tar exists, extract ISC and metadata to a temp dir
if [[ -f "$_transfer_tar" ]]; then
	_tmpdir=$(mktemp -d)

	# Extract just the ISC and metadata files (paths are relative to aba root)
	tar xf "$_transfer_tar" -C "$_tmpdir" \
		"mirror/data/imageset-config.yaml" \
		"mirror/data/aba-transfer-metadata.json" 2>/dev/null || true

	# Point to extracted files
	[[ -f "$_tmpdir/mirror/data/imageset-config.yaml" ]] && _isc_file="$_tmpdir/mirror/data/imageset-config.yaml"
	[[ -f "$_tmpdir/mirror/data/aba-transfer-metadata.json" ]] && _meta_file="$_tmpdir/mirror/data/aba-transfer-metadata.json"
	_source="transfer"
else
	_source="local"
fi

# Parse ISC for version, channel, operators
_ocp_version=""
_ocp_channel=""
_upgrade_to=""
_operators=""
_operator_count=0

if [[ -f "$_isc_file" ]]; then
	# Channel name format: "candidate-4.22" or "fast-5.0" (may be commented out)
	_chan_line=$(grep '^\s*- name:.*-[0-9]' "$_isc_file" | head -1 | sed 's/.*- name: *//' | xargs) || true
	if [[ -n "$_chan_line" ]]; then
		_ocp_channel="${_chan_line%%-[0-9]*}"
	fi

	_min_ver=$(grep '^\s*minVersion:' "$_isc_file" | head -1 | sed 's/.*minVersion: *//' | xargs) || true
	_max_ver=$(grep '^\s*maxVersion:' "$_isc_file" | head -1 | sed 's/.*maxVersion: *//' | xargs) || true
	_ocp_version="$_min_ver"

	if [[ -n "$_max_ver" && "$_max_ver" != "$_min_ver" ]]; then
		_upgrade_to="$_max_ver"
	fi

	# Extract operator package names from ISC YAML.
	# Each package block has: "- name: op-name" then "channels:" then "- name: chan".
	# Skip the channel "- name:" entries by tracking "channels:" sections.
	_operators=$(awk '
		/packages:/ { in_pkg=1; skip=0; next }
		/catalog:/ { in_pkg=0 }
		in_pkg && /channels:/ { skip=1; next }
		in_pkg && skip && /- name:/ { skip=0; next }
		in_pkg && /- name:/ { sub(/.*- name: */, ""); sub(/ *#.*/, ""); print }
	' "$_isc_file" | sort | paste -sd, -) || true
	if [[ -n "$_operators" ]]; then
		_operator_count=$(echo "$_operators" | tr ',' '\n' | wc -l)
	fi
fi

# Fill in from metadata JSON if present (supplements ISC when platform is commented out)
_created=""
if [[ -f "$_meta_file" ]]; then
	_meta_ver=$(grep '"ocp_version"' "$_meta_file" 2>/dev/null | sed 's/.*: *"//; s/".*//' || true)
	_meta_chan=$(grep '"ocp_channel"' "$_meta_file" 2>/dev/null | sed 's/.*: *"//; s/".*//' || true)
	_created=$(grep '"created"' "$_meta_file" 2>/dev/null | sed 's/.*: *"//; s/".*//' || true)
	if [[ -n "$_meta_chan" ]]; then
		_ocp_channel="$_meta_chan"
	fi
	if [[ -z "$_ocp_version" && -n "$_meta_ver" ]]; then
		_ocp_version="$_meta_ver"
	fi
fi

# Output
if [[ "$_shell_mode" == "true" ]]; then
	_pending=false
	[[ "$_source" == "transfer" ]] && _pending=true
	echo "transfer_pending=$_pending"
	echo "transfer_source=$_source"
	echo "transfer_ocp_version=$_ocp_version"
	echo "transfer_ocp_channel=$_ocp_channel"
	echo "transfer_upgrade_to=$_upgrade_to"
	echo "transfer_operator_count=$_operator_count"
	echo "transfer_operators=\"$_operators\""
	echo "transfer_created=\"$_created\""
else
	if [[ "$_source" == "transfer" ]]; then
		echo "Transfer bundle: $_transfer_tar"
	else
		echo "No transfer bundle found. Showing local ISC."
	fi

	local_ver="$_ocp_version"
	if [[ -n "$_upgrade_to" ]]; then
		local_ver="$_ocp_version → $_upgrade_to"
	fi
	echo "OCP: $local_ver ($_ocp_channel)"

	if [[ $_operator_count -gt 0 ]]; then
		echo "Operators ($_operator_count): $(echo "$_operators" | sed 's/,/, /g')"
	else
		echo "Operators: none"
	fi

	if [[ -n "${_created:-}" ]]; then
		echo "Created: $_created"
	fi
fi
