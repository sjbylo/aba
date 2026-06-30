#!/bin/bash
# list-operators.sh -- List all operators in a Red Hat operator catalog
#
# INTENT:    Replacement for "oc-mirror list operators --catalog <url>".
#            Pulls the catalog image, extracts FBC metadata, and lists operators
#            with display names and default channels. No oc-mirror dependency.
# CALLED BY: make list-operators, aba list-operators, TUI operator browser
# CWD:       ABA repo root
# REQUIRES:  podman, jq; container auth for registry.redhat.io
# ARGS:      <ocp_version> [catalog_name]
#            ocp_version:   e.g. "4.21" (major.minor only)
#            catalog_name:  redhat-operator (default) | certified-operator | community-operator
# PRODUCES:  stdout -- 3-column whitespace-padded table:
#              PACKAGE_NAME   DISPLAY_NAME   DEFAULT_CHANNEL
# SIDE EFFECTS: Catalog image remains in podman graph storage (cache for future runs).
# IDEMPOTENT: Yes (read-only extraction, no state files)
#
# Usage: list-operators.sh <version> [catalog]
# Example:
#   list-operators.sh 4.21
#   list-operators.sh 4.21 certified-operator
#   list-operators.sh 4.21 community-operator

set -eo pipefail
source scripts/include_all.sh

# ── Local output helpers (tool-specific [INFO]/[OK]/[ERROR] style) ────
if [ -t 1 ]; then
	_LO_RED='\033[0;31m'; _LO_GREEN='\033[0;32m'; _LO_BLUE='\033[0;34m'; _LO_NC='\033[0m'
else
	_LO_RED=''; _LO_GREEN=''; _LO_BLUE=''; _LO_NC=''
fi
info()    { echo -e "${_LO_BLUE}[INFO]${_LO_NC} $*" >&2; }
success() { echo -e "${_LO_GREEN}[OK]${_LO_NC} $*"   >&2; }
die()     { echo -e "${_LO_RED}[ERROR]${_LO_NC} $*"   >&2; exit 1; }

# ── Parse arguments ──────────────────────────────────────────────────
usage() {
	echo "Usage: $(basename "$0") <ocp_version> [catalog_name]"
	echo "  ocp_version   : e.g. 4.20, 4.21"
	echo "  catalog_name  : redhat-operator (default), certified-operator, community-operator"
	exit 1
}

ocp_ver="${1:?$(usage)}"
echo "$ocp_ver" | grep -qE '^[0-9]+\.[0-9]+$' || { echo "Error: version must be X.Y (e.g. 4.21)" >&2; usage; }
catalog="${2:-redhat-operator}"
catalog_url="registry.redhat.io/redhat/${catalog}-index:v${ocp_ver}"

# ── Prerequisites ────────────────────────────────────────────────────
command -v podman >/dev/null 2>&1 || die "podman is required"
command -v jq     >/dev/null 2>&1 || die "jq is required"

# ── Setup ────────────────────────────────────────────────────────────
container_name="list-ops-${catalog}-v${ocp_ver}-$$"
tmp_dir=$(mktemp -d "$ABA_TMP/list-ops-XXXXXX")
trap 'podman rm -f "$container_name" >/dev/null 2>&1; rm -rf "$tmp_dir"' EXIT INT TERM

# ── Pull image ───────────────────────────────────────────────────────
info "Pulling $catalog_url ..."
podman pull -q "$catalog_url" >/dev/null 2>&1 || die "Failed to pull $catalog_url — check credentials / network"

# ── Extract /configs ─────────────────────────────────────────────────
info "Extracting catalog data ..."
podman create -q --name "$container_name" "$catalog_url" >/dev/null 2>&1 \
	|| die "Failed to create container"
podman cp "$container_name:/configs" "$tmp_dir/configs" 2>/dev/null \
	|| die "Failed to copy /configs from container"
podman rm -f "$container_name" >/dev/null 2>&1

# ── Helpers ──────────────────────────────────────────────────────────

# Find the latest bundle file in a directory tree and extract displayName
_display_name_from_bundles() {
	local search_dir="$1"
	local dn=""

	# Collect all JSON bundle files (top-level and subdirectories)
	local bundle_files=()
	while IFS= read -r -d '' f; do
		bundle_files+=("$f")
	done < <(find "$search_dir" -name '*.json' -print0 2>/dev/null)

	if [ ${#bundle_files[@]} -gt 0 ]; then
		# Extract displayName from the last bundle's olm.csv.metadata
		# (last alphabetically ≈ latest version)
		for f in "${bundle_files[@]}"; do
			local candidate
			candidate=$(jq -r '
				if .schema == "olm.bundle" then
					(.properties[]? | select(.type=="olm.csv.metadata") | .value.displayName // empty)
				elif .properties then
					(.properties[]? | select(.type=="olm.csv.metadata") | .value.displayName // empty)
				else empty end
			' "$f" 2>/dev/null | head -1)
			[ -n "$candidate" ] && dn="$candidate"
		done
	fi

	echo "$dn"
}

# Extract package name + defaultChannel + displayName from JSON FBC file(s)
_extract_from_json() {
	local dir="$1"
	local pkg_src="$2"

	local pkg def_ch
	read -r pkg def_ch < <(jq -r 'select(.schema=="olm.package") | "\(.name) \(.defaultChannel)"' "$pkg_src" 2>/dev/null)
	[ -z "$pkg" ] || [ -z "$def_ch" ] && return 0

	# Try display name from the same file first (single-file catalogs)
	local display_name=""
	display_name=$(jq -r 'select(.schema=="olm.bundle") | .properties[]? | select(.type=="olm.csv.metadata") | .value.displayName // empty' "$pkg_src" 2>/dev/null | tail -1)

	# If not found, search all bundle files in the directory tree
	if [ -z "$display_name" ]; then
		display_name=$(_display_name_from_bundles "$dir")
	fi

	printf "%-55s %-60s %s\n" "$pkg" "${display_name:--}" "$def_ch"
}

# Extract from YAML FBC files (multi-document YAML separated by ---)
_extract_from_yaml() {
	local yaml_file="$1"
	local dir="$2"

	local pkg def_ch
	read -r pkg def_ch < <(awk '
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
	[ -z "$pkg" ] || [ -z "$def_ch" ] && return 0

	# Display name from CSV annotations in bundle sections
	local display_name=""
	display_name=$(grep '^ *displayName:' "$yaml_file" 2>/dev/null \
		| grep -v 'x-descriptors' \
		| tail -1 \
		| sed 's/.*displayName: *//' \
		| sed "s/^['\"]//;s/['\"]$//")

	printf "%-55s %-60s %s\n" "$pkg" "${display_name:--}" "$def_ch"
}

# ── Parse each operator directory ────────────────────────────────────
info "Parsing operators from $catalog v$ocp_ver ..."

for dir in "$tmp_dir/configs"/*/; do
	[ -d "$dir" ] || continue

	if [ -f "$dir/package.json" ]; then
		_extract_from_json "$dir" "$dir/package.json"
	elif [ -f "$dir/catalog.json" ]; then
		_extract_from_json "$dir" "$dir/catalog.json"
	elif [ -f "$dir/index.json" ]; then
		_extract_from_json "$dir" "$dir/index.json"
	elif ls "$dir"/*.yaml "$dir"/*.yml >/dev/null 2>&1; then
		# YAML catalog (catalog.yaml, catalog.yml, index.yaml, etc.)
		for yf in "$dir"/*.yaml "$dir"/*.yml; do
			[ -f "$yf" ] || continue
			_extract_from_yaml "$yf" "$dir"
			break
		done
	fi
done | sort

success "Done. Catalog: $catalog v$ocp_ver"
