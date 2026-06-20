#!/bin/bash
# download-catalog-index.sh -- Extract operator catalog index from a container image
#
# INTENT:    Pull an operator catalog image from registry.redhat.io, extract its
#            File-Based Catalog (FBC) metadata, and produce a sorted index of all
#            operators with their default channels. Also captures the catalog image
#            digest for runtime catalog pinning (see devel/01-SPEC.md "Catalog Digest
#            Pinning").
# CALLED BY: download-catalogs-start.sh via run_once (never directly by user)
# CWD:       ABA repo root (resolved from script location via symlink-safe pwd -P)
# REQUIRES:  podman, jq, curl; container auth (via create-containers-auth.sh);
#            internet access to registry.redhat.io
# ARGS:      <catalog_name> <version_short>
#            catalog_name:   redhat-operator | certified-operator | community-operator
#            version_short:  e.g. "4.21" (major.minor only)
# PRODUCES:
#   .index/{catalog}-index-v{ver}                 Sorted operator index (3-column TSV)
#   .index/.{catalog}-index-v{ver}.expected-count Expected operator count
#   .index/.{catalog}-index-v{ver}.digest         Manifest digest (sha256:...) for pinning
#   mirror/imageset-config-{catalog}-catalog-v{ver}.yaml  Helper YAML for reference
# IDEMPOTENT: run_once() with TTL is the sole gatekeeper -- script always does work when invoked.
#             Uses atomic rename (.downloading -> final) so consumers never see partial data.
#
# INDEX FORMAT (3 columns, whitespace-separated):
#   <package_name>  <display_name_or_dash>  <default_channel>
#
# Backward compatible with existing consumers that use:
#   awk '{print $1, $NF}'  => gets name (first) and channel (last)
#   grep "^$op "           => matches by operator name prefix
#
# STEPS:
#   1. Verify connectivity to registry.redhat.io
#   2. Pull catalog image (permissive signature policy for unsigned catalogs)
#   3. Capture manifest digest via podman image inspect (for catalog pinning)
#   4. Run container, extract /configs directory
#   5. Parse FBC data: JSON (package.json/catalog.json/index.json) or YAML
#   6. Sort and write to temp file, validate, atomic rename to final location
#   7. Record expected operator count
#   8. Generate helper YAML for reference

# Derive aba root from script location (this script is in scripts/)
# Use pwd -P to resolve symlinks (important when called via mirror/scripts/ symlink)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
cd "$SCRIPT_DIR/.." || exit 1

source scripts/include_all.sh

# Parse required parameters
catalog_name="${1:?Usage: $0 <catalog_name> <version_short>}"
ocp_ver_major="${2:?Usage: $0 <catalog_name> <version_short>}"

aba_debug "Catalog: $catalog_name, version: $ocp_ver_major"

# Prepare container auth — regcreds_dir must be set so create-containers-auth.sh
# merges mirror credentials into ~/.docker/config.json (not overwrites with Red Hat-only)
export regcreds_dir=$HOME/.aba/mirror/mirror
aba_debug "Creating container auth file (regcreds_dir=$regcreds_dir)"
scripts/create-containers-auth.sh >/dev/null || exit 1

# Setup paths - must be run from aba root directory
mkdir -p .index
index_file=".index/${catalog_name}-index-v${ocp_ver_major}"
tmp_file=".index/.${catalog_name}-index-v${ocp_ver_major}.downloading"

yaml_file="mirror/imageset-config-${catalog_name}-catalog-v${ocp_ver_major}.yaml"

aba_debug "Index file: $index_file"
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

# Cleanup on exit (catches signals, errors, aba_abort, TUI close — not just INT/TERM)
_cleanup() {
	[ -n "${container_name:-}" ] && podman rm -f "$container_name" >/dev/null 2>&1 || true
	[ -d "${tmp_dir:-}" ] && rm -rf "$tmp_dir"
	rm -f "${tmp_file:-}"
}
trap _cleanup EXIT

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

catalog_url="registry.redhat.io/redhat/${catalog_name}-index:v${ocp_ver_major}"
container_name="aba-catalog-${catalog_name}-v${ocp_ver_major}-$$"
tmp_dir=$(mktemp -d /tmp/.aba-catalog-XXXXXX)

# Sweep stale containers and temp dirs from previous interrupted runs
podman ps -a --format '{{.Names}}' | grep '^aba-catalog-' | while read -r _stale; do
	podman rm -f "$_stale" >/dev/null 2>&1
done
find /tmp -maxdepth 1 \( -name '.aba-catalog-*' -o -name '.aba-list-ops-*' -o -name 'render-registry-*' -o -name 'render-unpack-*' \) -user "$(id -un)" -mmin +1440 -exec rm -rf {} + 2>/dev/null || true

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
_pull_err=$(podman pull --signature-policy="$_sig_policy" -q "$catalog_url" 2>&1 >/dev/null) || {
	aba_abort "Failed to pull catalog image: $catalog_url" "$_pull_err"
}

# Capture manifest digest for runtime catalog pinning.
# When oc-mirror sees a digest ref it skips upstream tag resolution -- critical for air-gap.
digest_file=".index/.${catalog_name}-index-v${ocp_ver_major}.digest"
catalog_digest=$(podman image inspect --format '{{.Digest}}' "$catalog_url" 2>/dev/null) || catalog_digest=""
if [ "$catalog_digest" ]; then
	echo "$catalog_digest" > "$digest_file"
	aba_debug "Captured catalog digest: $catalog_digest"
else
	rm -f "$digest_file"
	aba_debug "Could not capture digest for $catalog_url -- tag will be used"
fi

# Run container and extract /configs
aba_info "Extracting catalog data for $catalog_name v$ocp_ver_major..."
_run_err=$(podman create -q --name "$container_name" "$catalog_url" 2>&1 >/dev/null) || {
	aba_abort "Failed to create catalog container" "$_run_err"
}

_cp_err=$(podman cp "$container_name:/configs" "$tmp_dir/configs" 2>&1) || {
	aba_abort "Failed to extract /configs from catalog container" "$_cp_err"
}

# Container no longer needed (EXIT trap handles cleanup, but remove early to free resources)
podman rm -f "$container_name" >/dev/null 2>&1 || true
container_name=""

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
		local candidate=""
		# Newer catalogs: olm.csv.metadata stores displayName directly
		candidate=$(jq -r '
			if .schema == "olm.bundle" then
				(.properties[]? | select(.type=="olm.csv.metadata") | .value.displayName // empty)
			elif .properties then
				(.properties[]? | select(.type=="olm.csv.metadata") | .value.displayName // empty)
			else empty end
		' "$f" 2>/dev/null | head -1)
		# Older catalogs (<=4.16): CSV is base64-encoded in olm.bundle.object
		if [ -z "$candidate" ]; then
			candidate=$(jq -r '
				select(.schema == "olm.bundle") |
				.properties[]? | select(.type == "olm.bundle.object") |
				.value.data
			' "$f" 2>/dev/null | base64 -d 2>/dev/null | jq -r '.spec.displayName // empty' 2>/dev/null | head -1)
		fi
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

	# Older catalogs (<=4.16): CSV is base64-encoded in olm.bundle.object
	if [ -z "$display_name" ]; then
		display_name=$(jq -r 'select(.schema=="olm.bundle") | .properties[]? | select(.type=="olm.bundle.object") | .value.data' "$pkg_src" 2>/dev/null | base64 -d 2>/dev/null | jq -r '.spec.displayName // empty' 2>/dev/null | tail -1)
	fi

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

	# Display name from CSV annotation in bundle documents.
	# Search the given file first, then sibling YAML/JSON files in the same directory.
	local display_name="" dn="" dir_path
	dir_path="$(dirname "$yaml_file")"
	dn=$(grep '^ *displayName:' "$yaml_file" 2>/dev/null | grep -v 'x-descriptors' | tail -1 | sed 's/.*displayName: *//' | sed "s/^['\"]//;s/['\"]$//")
	if [ -z "$dn" ]; then
		while IFS= read -r -d '' _sf; do
			[ "$_sf" = "$yaml_file" ] && continue
			dn=$(grep '^ *displayName:' "$_sf" 2>/dev/null | grep -v 'x-descriptors' | tail -1 | sed 's/.*displayName: *//' | sed "s/^['\"]//;s/['\"]$//")
			[ -n "$dn" ] && break
		done < <(find "$dir_path" \( -name '*.yaml' -o -name '*.yml' -o -name '*.json' \) -print0 2>/dev/null)
	fi
	display_name="${dn:--}"

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
	elif [ -f "$dir/package.yaml" ]; then
		_extract_from_yaml "$dir/package.yaml"
	elif compgen -G "$dir"'*.yaml' >/dev/null 2>&1 || compgen -G "$dir"'*.yml' >/dev/null 2>&1; then
		for yf in "$dir"/*.yaml "$dir"/*.yml; do
			[ -f "$yf" ] || continue
			_extract_from_yaml "$yf" && break
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

sort "$_raw_file" > "$tmp_file"

# Record expected operator count (exclude internal metadata dirs starting with _)
expected_count_file=".index/.${catalog_name}-index-v${ocp_ver_major}.expected-count"
find "$tmp_dir/configs" -mindepth 1 -maxdepth 1 -type d -not -name '_*' 2>/dev/null | wc -l > "$expected_count_file"

# Cleanup temp dir
rm -rf "$tmp_dir"

# Validate output
if [ ! -s "$tmp_file" ]; then
	aba_abort "Catalog extraction produced empty index for $catalog_name v$ocp_ver_major"
fi

# Atomic rename: consumers never see a partial file
mv "$tmp_file" "$index_file"

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

aba_info_ok "Extracted $catalog_name index v$ocp_ver_major ($op_count operators)"

_generate_yaml
aba_info "Generated $yaml_file for reference"

exit 0
