#!/usr/bin/env bash
# =============================================================================
# INTENT:      Manage curated image sets (AI, Virt, OCP) in images.conf
# CALLED BY:   TUI (tui-mirror.sh), sourced via include_all.sh
# CWD:         Varies (caller's working directory)
# REQUIRES:    ABA_ROOT set, templates/image-set-* files, internet for AI set
# PRODUCES:    Modifications to images.conf (marker blocks)
# =============================================================================
# Image sets are curated lists of additional container images that complement
# operator sets (e.g. RHOAI notebook images for the AI operator set, container
# disk images for Virtualization). Static sets are read from template files;
# the AI set is fetched dynamically from GitHub per RHOAI release.
#
# Marker block format in images.conf:
#   # image-set: <name> [(<detail>)]
#   <image-ref>
#   ...
#   # end-image-set: <name>
# =============================================================================

[[ "${_IMAGE_SETS_LOADED:-}" == "true" ]] && return 0
_IMAGE_SETS_LOADED=true

# Operator set → companion image set mapping
declare -gA _IMAGE_SET_COMPANIONS=(
	[ai]="ai"
	[virt]="virt"
)

_RHOAI_GITHUB_RAW="https://raw.githubusercontent.com/red-hat-data-services/rhoai-disconnected-install-helper/main"
_RHOAI_GITHUB_API="https://api.github.com/repos/red-hat-data-services/rhoai-disconnected-install-helper/contents"
_RHOAI_CACHE_DIR="$HOME/.aba/cache/rhoai"

# ---------------------------------------------------------------------------
# _image_set_is_dynamic <set_name>
#   Returns 0 if the set is dynamic (fetched at runtime), 1 if static.
# ---------------------------------------------------------------------------
_image_set_is_dynamic() {
	local set_file="$ABA_ROOT/templates/image-set-$1"
	[ -f "$set_file" ] || return 1
	grep -q '^# Dynamic:' "$set_file" 2>/dev/null
}

# ---------------------------------------------------------------------------
# _image_set_display_name <set_name>
#   Reads the "# Name: ..." line from the template file.
# ---------------------------------------------------------------------------
_image_set_display_name() {
	local set_file="$ABA_ROOT/templates/image-set-$1"
	[ -f "$set_file" ] || return 1
	local name
	name=$(head -n1 "$set_file" 2>/dev/null | sed 's/^# *//' | sed 's/^Name: *//')
	echo "${name:-$1}"
}

# ---------------------------------------------------------------------------
# _image_set_static_images <set_name>
#   Reads a static image set template, outputs one image ref per line.
# ---------------------------------------------------------------------------
_image_set_static_images() {
	local set_file="$ABA_ROOT/templates/image-set-$1"
	[ -f "$set_file" ] || return 1
	sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' "$set_file"
}

# ---------------------------------------------------------------------------
# _image_set_marker_exists <set_name> [images_conf_path]
#   Returns 0 if the marker block for <set_name> exists in images.conf.
# ---------------------------------------------------------------------------
_image_set_marker_exists() {
	local set_name="$1"
	local img_file="${2:-$ABA_ROOT/images.conf}"
	[ -f "$img_file" ] || return 1
	grep -q "^# image-set: $set_name" "$img_file" 2>/dev/null
}

# ---------------------------------------------------------------------------
# _image_set_marker_detail <set_name> [images_conf_path]
#   Outputs the detail string from the marker (e.g. "rhoai-3.5.1").
# ---------------------------------------------------------------------------
_image_set_marker_detail() {
	local set_name="$1"
	local img_file="${2:-$ABA_ROOT/images.conf}"
	[ -f "$img_file" ] || return 1
	local line
	line=$(grep "^# image-set: $set_name" "$img_file" 2>/dev/null | head -1)
	if echo "$line" | grep -q '('; then
		echo "$line" | sed 's/.*(\(.*\)).*/\1/'
	fi
}

# ---------------------------------------------------------------------------
# _image_set_marker_count <set_name> [images_conf_path]
#   Counts image refs inside the marker block.
# ---------------------------------------------------------------------------
_image_set_marker_count() {
	local set_name="$1"
	local img_file="${2:-$ABA_ROOT/images.conf}"
	[ -f "$img_file" ] || { echo 0; return; }
	awk -v name="$set_name" '
		/^# image-set: / && $3 == name { capture=1; next }
		/^# end-image-set: / && $3 == name { capture=0; next }
		capture && /^[^#]/ && NF { count++ }
		END { print count+0 }
	' "$img_file"
}

# ---------------------------------------------------------------------------
# detect_rhoai_version [ocp_ver_short]
#   Auto-detect the latest GA RHOAI version from the operator channel.
#   Reads rhods-operator channel from the catalog index, extracts the major
#   series, queries GitHub for available versions, picks latest GA.
#   Outputs version string (e.g. "3.5.1") on stdout.
#   Returns 1 on failure.
# ---------------------------------------------------------------------------
detect_rhoai_version() {
	local ocp_ver="${1:-}"
	if [ -z "$ocp_ver" ]; then
		source <(normalize-aba-conf) 2>/dev/null
		ocp_ver=$(_ver_minor "${ocp_version:-}")
	fi
	[ -z "$ocp_ver" ] && return 1

	# Check cache first
	mkdir -p "$_RHOAI_CACHE_DIR"
	local cache_file="$_RHOAI_CACHE_DIR/detected-version-${ocp_ver}.txt"
	if [ -f "$cache_file" ]; then
		cat "$cache_file"
		return 0
	fi

	# Read rhods-operator channel from catalog index
	local index_file="$ABA_ROOT/.index/redhat-operator-index-v${ocp_ver}"
	[ -f "$index_file" ] || { aba_debug "No catalog index for OCP $ocp_ver"; return 1; }

	local channel
	channel=$(awk '$1 == "rhods-operator" { print $NF }' "$index_file")
	[ -z "$channel" ] && { aba_debug "rhods-operator not found in catalog for OCP $ocp_ver"; return 1; }

	# Extract major series from channel name (e.g. "stable-3.x" → "3")
	local series
	series=$(echo "$channel" | sed -n 's/.*-\([0-9][0-9]*\)\..*/\1/p')
	[ -z "$series" ] && { aba_debug "Cannot parse series from channel '$channel'"; return 1; }

	# Query GitHub API for available RHOAI ISC files matching this series
	local api_response
	api_response=$(curl -sL --connect-timeout 10 --max-time 30 "$_RHOAI_GITHUB_API" 2>/dev/null) || return 1
	[ -z "$api_response" ] && return 1

	# Extract version numbers, filter to this series, exclude EA, sort by version, pick latest
	local latest
	latest=$(echo "$api_response" \
		| grep -o '"rhoai-[0-9][^"]*-imagesetconfig\.yaml"' \
		| sed 's/"rhoai-\(.*\)-imagesetconfig\.yaml"/\1/' \
		| grep "^${series}\." \
		| grep -v '\-ea' \
		| sort -t. -k1,1n -k2,2n -k3,3n \
		| tail -1)
	[ -z "$latest" ] && { aba_debug "No GA RHOAI $series.x found on GitHub"; return 1; }

	# Cache and output
	echo "$latest" > "$cache_file"
	echo "$latest"
}

# ---------------------------------------------------------------------------
# fetch_rhoai_images <version>
#   Download RHOAI image list from GitHub, extract additionalImages refs.
#   Caches in ~/.aba/cache/rhoai/rhoai-<version>-images.txt.
#   Outputs one image ref per line on stdout.
# ---------------------------------------------------------------------------
fetch_rhoai_images() {
	local version="$1"
	[ -z "$version" ] && return 1

	mkdir -p "$_RHOAI_CACHE_DIR"
	local cache_file="$_RHOAI_CACHE_DIR/rhoai-${version}-images.txt"

	# Return cached if available
	if [ -f "$cache_file" ] && [ -s "$cache_file" ]; then
		cat "$cache_file"
		return 0
	fi

	# Fetch the ISC file from GitHub
	local url="${_RHOAI_GITHUB_RAW}/rhoai-${version}-imagesetconfig.yaml"
	local isc_content
	isc_content=$(curl -sL --connect-timeout 10 --max-time 60 "$url" 2>/dev/null) || return 1
	[ -z "$isc_content" ] && return 1

	# Extract additionalImages - name: lines (strip leading whitespace and "- name: ")
	local images
	images=$(echo "$isc_content" \
		| awk '/additionalImages:/{p=1; next} p && /^[^ ]/{exit} p && /- name:/{print}' \
		| sed 's/.*- name: *//' \
		| sed 's/[[:space:]]*$//')
	[ -z "$images" ] && return 1

	# Cache and output
	echo "$images" > "$cache_file"
	echo "$images"
}

# ---------------------------------------------------------------------------
# image_set_list [images_conf_path]
#   List available image sets with name, display name, status, image count.
#   Output format (tab-separated, one set per line):
#     <name>\t<display_name>\t<status>\t<count>\t<detail>
#   status: "added" or "available"
#   detail: e.g. "rhoai-3.5.1" for AI, empty for static sets
# ---------------------------------------------------------------------------
image_set_list() {
	local img_file="${1:-$ABA_ROOT/images.conf}"
	local set_file set_name display status count detail

	for set_file in "$ABA_ROOT"/templates/image-set-*; do
		[ -f "$set_file" ] || continue
		set_name="${set_file##*image-set-}"
		display=$(_image_set_display_name "$set_name")

		if _image_set_marker_exists "$set_name" "$img_file"; then
			status="added"
			count=$(_image_set_marker_count "$set_name" "$img_file")
			detail=$(_image_set_marker_detail "$set_name" "$img_file")
		else
			status="available"
			detail=""
			if _image_set_is_dynamic "$set_name"; then
				count="~50"
			else
				count=$(_image_set_static_images "$set_name" | wc -l)
			fi
		fi

		printf '%s\t%s\t%s\t%s\t%s\n' "$set_name" "$display" "$status" "$count" "$detail"
	done
}

# ---------------------------------------------------------------------------
# image_set_add <set_name> [rhoai_version]
#   Add an image set to images.conf. For static sets, reads the template.
#   For AI, fetches from GitHub (auto-detects version if not provided).
#   If the set already exists, replaces it (re-add = refresh).
#   Outputs the number of images added on stdout.
#   Returns 1 on failure.
# ---------------------------------------------------------------------------
image_set_add() {
	local set_name="$1"
	local version="${2:-}"
	local img_file="$ABA_ROOT/images.conf"
	local set_file="$ABA_ROOT/templates/image-set-$set_name"

	[ -f "$set_file" ] || { aba_debug "image_set_add: no template for '$set_name'"; return 1; }

	# Get the image list
	local images=""
	local detail=""

	if _image_set_is_dynamic "$set_name"; then
		# Dynamic set (AI): detect version if not provided
		if [ -z "$version" ]; then
			version=$(detect_rhoai_version) || return 1
		fi
		images=$(fetch_rhoai_images "$version") || return 1
		detail="rhoai-$version"
	else
		# Static set: read from template
		images=$(_image_set_static_images "$set_name") || return 1
	fi

	[ -z "$images" ] && return 1

	# Remove existing marker block if present (re-add = replace)
	if _image_set_marker_exists "$set_name" "$img_file"; then
		image_set_remove "$set_name" || true
	fi

	# Ensure images.conf exists
	touch "$img_file"

	# Append marker block
	{
		echo ""
		if [ -n "$detail" ]; then
			echo "# image-set: $set_name ($detail)"
		else
			echo "# image-set: $set_name"
		fi
		echo "$images"
		echo "# end-image-set: $set_name"
	} >> "$img_file"

	# Count and output
	echo "$images" | wc -l
}

# ---------------------------------------------------------------------------
# image_set_remove <set_name> [images_conf_path]
#   Remove the marker block for <set_name> from images.conf.
#   Returns 1 if no marker found.
# ---------------------------------------------------------------------------
image_set_remove() {
	local set_name="$1"
	local img_file="${2:-$ABA_ROOT/images.conf}"

	[ -f "$img_file" ] || return 1
	_image_set_marker_exists "$set_name" "$img_file" || return 1

	# Remove the marker block (start marker through end marker, inclusive)
	# Also remove the blank line before the start marker if present
	local tmp="${img_file}.tmp.$$"
	awk -v name="$set_name" '
		# Match blank line immediately before start marker
		/^$/ && !skip { hold=1; next }
		/^# image-set: / && $3 == name { skip=1; hold=0; next }
		/^# end-image-set: / && $3 == name { skip=0; next }
		skip { next }
		hold { print ""; hold=0 }
		{ print }
	' "$img_file" > "$tmp"
	mv -f "$tmp" "$img_file"
}

# ---------------------------------------------------------------------------
# image_set_status <set_name> [images_conf_path]
#   Returns 0 if image set is in images.conf, 1 otherwise.
#   Outputs "<count> <detail>" on stdout (e.g. "50 rhoai-3.5.1" or "3").
# ---------------------------------------------------------------------------
image_set_status() {
	local set_name="$1"
	local img_file="${2:-$ABA_ROOT/images.conf}"

	_image_set_marker_exists "$set_name" "$img_file" || return 1

	local count detail
	count=$(_image_set_marker_count "$set_name" "$img_file")
	detail=$(_image_set_marker_detail "$set_name" "$img_file")
	echo "$count ${detail:-}"
}

# ---------------------------------------------------------------------------
# image_set_companions_needed <set1> [set2 ...]
#   Given operator set names, return companion image sets that are NOT yet
#   in images.conf. Output: one set name per line.
# ---------------------------------------------------------------------------
image_set_companions_needed() {
	local img_file="$ABA_ROOT/images.conf"
	local op_set companion

	for op_set in "$@"; do
		companion="${_IMAGE_SET_COMPANIONS[$op_set]:-}"
		[ -z "$companion" ] && continue
		# Only offer if the template exists and not already added
		[ -f "$ABA_ROOT/templates/image-set-$companion" ] || continue
		_image_set_marker_exists "$companion" "$img_file" && continue
		echo "$companion"
	done | sort -u
}
