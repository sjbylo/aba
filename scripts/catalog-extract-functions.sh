#!/bin/bash
# catalog-extract-functions.sh -- Shared FBC catalog extraction functions
#
# Sourced by:
#   scripts/download-catalog-index.sh   (local catalog extraction)
#   .github/workflows/refresh-catalog-indexes.yml  (GH Action)
#
# No ABA-specific dependencies (no include_all.sh). Safe to source from
# any bash environment with jq, awk, grep, find, and base64 available.
#
# Provides:
#   _display_name_from_bundles DIR   — extract display name from bundle JSON files
#   _extract_from_json DIR PKG_SRC   — extract operator info from JSON FBC data
#   _extract_from_yaml YAML_FILE     — extract operator info from YAML FBC data
#   _extract_catalog_dir DIR OUTFILE  — iterate operator dirs, write sorted index
#
# Output format (3 columns, whitespace-padded):
#   <package_name>  <display_name_or_dash>  <default_channel>

_display_name_from_bundles() {
	local search_dir="$1"
	local dn=""
	while IFS= read -r -d '' f; do
		local candidate=""
		candidate=$(jq -r '
			if .schema == "olm.bundle" then
				(.properties[]? | select(.type=="olm.csv.metadata") | .value.displayName // empty)
			elif .properties then
				(.properties[]? | select(.type=="olm.csv.metadata") | .value.displayName // empty)
			else empty end
		' "$f" 2>/dev/null | head -1)
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

	local pkg="" def_ch=""
	read -r pkg def_ch < <(jq -r 'select(.schema=="olm.package") | "\(.name) \(.defaultChannel)"' "$pkg_src" 2>/dev/null) || true

	if [ -z "$pkg" ] || [ -z "$def_ch" ]; then
		local f
		for f in "$dir"/*.json; do
			[ -f "$f" ] || continue
			[ "$f" = "$pkg_src" ] && continue
			read -r pkg def_ch < <(jq -r 'select(.schema=="olm.package") | "\(.name) \(.defaultChannel)"' "$f" 2>/dev/null) || true
			[ -n "$pkg" ] && [ -n "$def_ch" ] && break
		done
	fi
	[ -z "$pkg" ] || [ -z "$def_ch" ] && return 1

	local display_name=""
	display_name=$(jq -r 'select(.schema=="olm.bundle") | .properties[]? | select(.type=="olm.csv.metadata") | .value.displayName // empty' "$pkg_src" 2>/dev/null | tail -1)

	if [ -z "$display_name" ]; then
		display_name=$(jq -r 'select(.schema=="olm.bundle") | .properties[]? | select(.type=="olm.bundle.object") | .value.data' "$pkg_src" 2>/dev/null | base64 -d 2>/dev/null | jq -r '.spec.displayName // empty' 2>/dev/null | tail -1)
	fi

	if [ -z "$display_name" ]; then
		display_name=$(_display_name_from_bundles "$dir")
	fi

	printf "%-55s %-60s %s\n" "$pkg" "${display_name:--}" "$def_ch"
}

_extract_from_yaml() {
	local yf="$1"

	local pkg="" def_ch=""
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
	' "$yf" 2>/dev/null) || true
	[ -z "$pkg" ] || [ -z "$def_ch" ] && return 1

	local display_name="" dn="" dir_path
	dir_path="$(dirname "$yf")"
	dn=$(grep '^ *displayName:' "$yf" 2>/dev/null | grep -v 'x-descriptors' | tail -1 | sed 's/.*displayName: *//' | sed "s/^['\"]//;s/['\"]$//")
	if [ -z "$dn" ]; then
		while IFS= read -r -d '' _sf; do
			[ "$_sf" = "$yf" ] && continue
			dn=$(grep '^ *displayName:' "$_sf" 2>/dev/null | grep -v 'x-descriptors' | tail -1 | sed 's/.*displayName: *//' | sed "s/^['\"]//;s/['\"]$//")
			[ -n "$dn" ] && break
		done < <(find "$dir_path" \( -name '*.yaml' -o -name '*.yml' -o -name '*.json' \) -print0 2>/dev/null)
	fi
	display_name="${dn:--}"

	printf "%-55s %-60s %s\n" "$pkg" "$display_name" "$def_ch"
}

# _extract_catalog_dir CONFIGS_DIR OUTFILE [SKIPPED_FILE]
#   Iterate all operator subdirectories in CONFIGS_DIR, extract index data,
#   write sorted output to OUTFILE. Optionally record skipped dirs.
_extract_catalog_dir() {
	local configs_dir="$1" outfile="$2" skipped_file="${3:-/dev/null}"

	(
		set +e
		for dir in "$configs_dir"/*/; do
			[ -d "$dir" ] || continue
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
				_found=
				for f in "$dir"/*.json; do
					[ -f "$f" ] || continue
					if _extract_from_json "$dir" "$f"; then
						_found=1
						break
					fi
				done
				[ -z "$_found" ] && echo "$(basename "$dir")" >> "$skipped_file"
			fi
		done
	) | sort > "$outfile"
}
