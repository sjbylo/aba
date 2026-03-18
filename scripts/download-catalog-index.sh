#!/bin/bash
# Download operator catalog index by extracting it from the container image using podman.
#
# Usage: download-catalog-index.sh <catalog_name> <version_short>
# Example: download-catalog-index.sh redhat-operator 4.21
#
# Output format (3 columns, whitespace-separated):
#   <package_name>  <display_name_or_dash>  <default_channel>
#
# Backward compatible with existing consumers that use:
#   awk '{print $1, $NF}'  => gets name (first) and channel (last)
#   grep "^$op "           => matches by operator name prefix
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
scripts/create-containers-auth.sh >/dev/null || exit 1

# Setup paths - must be run from aba root directory
mkdir -p .index
index_file=".index/${catalog_name}-index-v${ocp_ver_major}"
done_file=".index/.${catalog_name}-index-v${ocp_ver_major}.done"

yaml_file="mirror/imageset-config-${catalog_name}-catalog-v${ocp_ver_major}.yaml"

aba_debug "Index file: $index_file"
aba_debug "Done file: $done_file"
aba_debug "YAML file: $yaml_file"

# Generate the helper YAML from the index file
_generate_yaml() {
	[ -s "$index_file" ] || return 0
	awk '{print $1,$NF}' "$index_file" | while read op_name op_default_channel; do
		echo "    - name: $op_name"
		echo "      channels:"
		echo "      - name: \"$op_default_channel\""
	done > "$yaml_file"
}

# Cleanup on interrupt
handle_interrupt() {
	echo_red "Aborting catalog extraction for $catalog_name"
	[ ! -f "$done_file" ] && rm -f "$index_file" "$done_file"
	# Clean up container and temp dir
	podman rm -f "$container_name" >/dev/null 2>&1
	[ -d "$tmp_dir" ] && rm -rf "$tmp_dir"
	exit 1
}
trap 'handle_interrupt' INT TERM

# Check if already downloaded
if [[ -s "$index_file" && -f "$done_file" ]]; then
	aba_debug "Index already exists and is complete for $catalog_name v$ocp_ver_major"
	[ -s "$yaml_file" ] || _generate_yaml
	exit 0
fi
aba_debug "Index not found or incomplete - starting extraction"

# Check connectivity to registry
aba_debug "Checking connectivity to registry.redhat.io"
if ! curl --connect-timeout 15 --retry 8 -IL http://registry.redhat.io/v2 >/dev/null 2>&1; then
	aba_abort "Cannot access registry.redhat.io - check internet connection"
fi

# Verify prerequisites
if ! command -v podman >/dev/null 2>&1; then
	aba_abort "podman is required but not installed"
fi
if ! command -v jq >/dev/null 2>&1; then
	aba_abort "jq is required but not installed"
fi

# Initialize
[ ! -f "$index_file" ] && touch "$index_file"
rm -f "$done_file"

catalog_url="registry.redhat.io/redhat/${catalog_name}-index:v${ocp_ver_major}"
container_name="aba-catalog-${catalog_name}-v${ocp_ver_major}-$$"
tmp_dir=$(mktemp -d)

aba_debug "catalog_url=$catalog_url"
aba_debug "container_name=$container_name"
aba_debug "tmp_dir=$tmp_dir"

# Pull the catalog image
# Some catalog images (certified, community) may be signed with keys not in
# the local trust store. Use a permissive signature policy for the pull since
# we only read catalog metadata from the image.
_sig_policy="$tmp_dir/policy.json"
echo '{"default":[{"type":"insecureAcceptAnything"}]}' > "$_sig_policy"

aba_info "Pulling operator catalog image: $catalog_url"
if ! podman pull --signature-policy="$_sig_policy" -q "$catalog_url" >/dev/null 2>&1; then
	rm -rf "$tmp_dir"
	aba_abort "Failed to pull catalog image: $catalog_url"
fi

# Run container and extract /configs
aba_info "Extracting catalog data for $catalog_name v$ocp_ver_major..."
if ! podman run -q -d --name "$container_name" "$catalog_url" >/dev/null 2>&1; then
	rm -rf "$tmp_dir"
	aba_abort "Failed to start catalog container"
fi

if ! podman cp "$container_name:/configs" "$tmp_dir/configs" 2>/dev/null; then
	podman rm -f "$container_name" >/dev/null 2>&1
	rm -rf "$tmp_dir"
	aba_abort "Failed to extract /configs from catalog container"
fi

# Container no longer needed
podman rm -f "$container_name" >/dev/null 2>&1

# Extract operator data from FBC (File-Based Catalog)
# Each operator directory under /configs can use one of several formats:
#   - Split JSON:  package.json + channels.json + bundles.json
#   - Single JSON: catalog.json or index.json
#   - Single YAML: catalog.yaml
#   - Mixed:       index.json + bundle-*.json
aba_info "Parsing catalog data..."

_display_name_from_bundles() {
	local search_dir="$1"
	local dn=""
	while IFS= read -r -d '' f; do
		local candidate
		candidate=$(jq -r '
			if .schema == "olm.bundle" then
				(.properties[]? | select(.type=="olm.csv.metadata") | .value.displayName // empty)
			elif .properties then
				(.properties[]? | select(.type=="olm.csv.metadata") | .value.displayName // empty)
			else empty end
		' "$f" 2>/dev/null | head -1)
		[ -n "$candidate" ] && dn="$candidate"
	done < <(find "$search_dir" -name '*.json' -print0 2>/dev/null)
	echo "$dn"
}

_extract_from_json() {
	local dir="$1" pkg_src="$2"

	local pkg def_ch
	read -r pkg def_ch < <(jq -r 'select(.schema=="olm.package") | "\(.name) \(.defaultChannel)"' "$pkg_src" 2>/dev/null)

	# Some catalogs split olm.package into channel-specific JSON files
	if [ -z "$pkg" ] || [ -z "$def_ch" ]; then
		local f
		for f in "$dir"/*.json; do
			[ -f "$f" ] || continue
			[ "$f" = "$pkg_src" ] && continue
			read -r pkg def_ch < <(jq -r 'select(.schema=="olm.package") | "\(.name) \(.defaultChannel)"' "$f" 2>/dev/null)
			[ -n "$pkg" ] && [ -n "$def_ch" ] && break
		done
	fi
	[ -z "$pkg" ] || [ -z "$def_ch" ] && return 1

	# Try display name from the package source file first (single-file catalogs)
	local display_name=""
	display_name=$(jq -r 'select(.schema=="olm.bundle") | .properties[]? | select(.type=="olm.csv.metadata") | .value.displayName // empty' "$pkg_src" 2>/dev/null | tail -1)

	# Fall back to recursive search of all bundle files in the directory tree
	if [ -z "$display_name" ]; then
		display_name=$(_display_name_from_bundles "$dir")
	fi

	printf "%-55s %-60s %s\n" "$pkg" "${display_name:--}" "$def_ch"
}

_extract_from_yaml() {
	local yaml_file="$1"

	# YAML documents are separated by '---'. Fields within a document
	# can appear in any order, so collect per-document and check schema.
	local pkg def_ch
	read pkg def_ch < <(awk '
		/^---/ {
			if (schema == "olm.package" && name && defch) { print name, defch; exit }
			name=""; defch=""; schema=""
		}
		/^name: /           { name=$2 }
		/^defaultChannel: / { defch=$2 }
		/^schema: /         { schema=$2 }
		END {
			if (schema == "olm.package" && name && defch) print name, defch
		}
	' "$yaml_file" 2>/dev/null)
	[ -z "$pkg" ] || [ -z "$def_ch" ] && return 1

	# Display name from CSV annotation in bundle documents
	local display_name="-"
	local dn
	dn=$(grep '^ *displayName:' "$yaml_file" 2>/dev/null | grep -v 'x-descriptors' | tail -1 | sed 's/.*displayName: *//' | sed "s/^['\"]//;s/['\"]$//")
	[ -n "$dn" ] && display_name="$dn"

	printf "%-55s %-60s %s\n" "$pkg" "$display_name" "$def_ch"
}

_raw_file="$tmp_dir/.raw-index"
_skipped_file="$tmp_dir/.skipped-dirs"
> "$_skipped_file"

for dir in "$tmp_dir/configs"/*/; do
	[[ "$(basename "$dir")" == _* ]] && continue
	if [ -f "$dir/package.json" ]; then
		_extract_from_json "$dir" "$dir/package.json"
	elif [ -f "$dir/catalog.json" ]; then
		_extract_from_json "$dir" "$dir/catalog.json"
	elif [ -f "$dir/index.json" ]; then
		_extract_from_json "$dir" "$dir/index.json"
	elif compgen -G "$dir"'*.yaml' >/dev/null 2>&1 || compgen -G "$dir"'*.yml' >/dev/null 2>&1; then
		for yf in "$dir"/*.yaml "$dir"/*.yml; do
			[ -f "$yf" ] || continue
			_extract_from_yaml "$yf"
			break
		done
	else
		# Generic fallback: scan all JSON files for olm.package entries
		_found=
		for f in "$dir"/*.json; do
			[ -f "$f" ] || continue
			if _extract_from_json "$dir" "$f"; then
				_found=1
				break
			fi
		done
		[ -z "$_found" ] && echo "$(basename "$dir")" >> "$_skipped_file"
	fi
done > "$_raw_file"

sort "$_raw_file" > "$index_file"

# Record expected operator count (exclude internal metadata dirs starting with _)
expected_count_file=".index/.${catalog_name}-index-v${ocp_ver_major}.expected-count"
find "$tmp_dir/configs" -mindepth 1 -maxdepth 1 -type d -not -name '_*' 2>/dev/null | wc -l > "$expected_count_file"

# Cleanup temp dir and container image
rm -rf "$tmp_dir"
podman rmi "$catalog_url" >/dev/null 2>&1 || true

# Validate output
if [ ! -s "$index_file" ]; then
	aba_abort "Catalog extraction produced empty index for $catalog_name v$ocp_ver_major"
fi

op_count=$(wc -l < "$index_file")
expected_count=0
[ -f "$expected_count_file" ] && expected_count=$(< "$expected_count_file")
skipped_count=0
[ -s "$_skipped_file" ] && skipped_count=$(wc -l < "$_skipped_file")

# End-of-extraction summary (only when there are issues)
if (( skipped_count > 0 )) || { (( expected_count > 0 )) && (( op_count != expected_count )); }; then
	aba_info "Warning: Catalog extraction summary for $catalog_name v$ocp_ver_major:"
	aba_info "  Extracted: ${op_count}/${expected_count} operators"
	if (( skipped_count > 0 )); then
		aba_info "  Skipped directories (no olm.package found):"
		while IFS= read -r d; do
			aba_info "    - $d"
		done < "$_skipped_file"
	fi
fi

# Mark completion
touch "$done_file"
aba_info_ok "Extracted $catalog_name index v$ocp_ver_major ($op_count operators)"

_generate_yaml
aba_info "Generated $yaml_file for reference"

exit 0
