#!/bin/bash
# catalog-extract-functions.sh -- Shared FBC catalog extraction functions
#
# Sourced by:
#   scripts/download-catalog-index.sh   (local catalog extraction)
#   scripts/list-operators.sh           (aba list-operators / TUI browser)
#
# No ABA-specific dependencies (no include_all.sh). Safe to source from
# any bash environment with jq, awk, grep, find, and base64 available.
#
# Provides:
#   _index_unquote STR              — peel wrapping ' or " from a YAML scalar
#   _index_print PKG DISPLAY CH     — one index line (display defaults to -)
#   _index_syntax_bad_lines FILE    — print malformed index lines (quoted name/channel, …)
#   _index_missing_display_lines FILE — print lines whose display name is missing (-)
#   _csv_display_name_from_b64 B64  — displayName from one olm.bundle.object blob
#   _display_name_from_json_file F  — csv.metadata or per-blob CSV decode
#   _display_name_from_yaml_file F  — YAML displayName: or per-blob CSV decode
#   _display_name_from_bundles DIR  — extract display name from bundle JSON/YAML files
#   _extract_from_json DIR PKG_SRC  — extract operator info from JSON FBC data
#   _extract_from_yaml YAML_FILE    — extract operator info from YAML FBC data
#   _extract_catalog_dir DIR OUTFILE [SKIPPED_FILE]

#
# Output format (whitespace-separated, not column-padded):
#   <package_name> <display_name_or_dash> <default_channel>
# Package and channel have no spaces. Display name may contain spaces.
# Consumers use $1 (package) and $NF (channel). Do not pad — UTF-8 marks and
# long names make fixed/dynamic column widths a lie.

# Peel a single leading/trailing ' or " from a YAML scalar. No-op if unquoted.
_index_unquote() {
	printf '%s' "$1" | sed "s/^['\"]//;s/['\"]$//"
}

# One record. Display names may contain spaces; package and channel must not.
_index_print() {
	printf '%s %s %s\n' "$1" "${2:--}" "$3"
}

# Index contract: package name and channel are never quoted. Fail any line that
# wraps $1 or $NF in " (do not relax the $NF ~ /"/ / token checks to allow ").
_index_syntax_bad_lines() {
	awk '!/^[a-z0-9][a-z0-9._-]+[[:space:]]/ || NF < 3 || $1 ~ /"/ || $NF ~ /"/ || $NF !~ /^[a-zA-Z0-9][a-zA-Z0-9._-]*$/' "$1"
}

# Missing display name is a lone "-" between package and channel.
_index_missing_display_lines() {
	awk '{
		dn = $0
		sub(/^[^[:space:]]+[[:space:]]+/, "", dn)
		sub(/[[:space:]]+[^[:space:]]+$/, "", dn)
		if (dn == "" || dn == "-") print
	}' "$1"
}

_jq_olm_package() {
	# catalog.json is often concatenated JSON values, not one document.
	jq -n -r 'inputs | (if type == "array" then .[] else . end) | select(.schema=="olm.package") | "\(.name) \(.defaultChannel)"' "$1" 2>/dev/null
}

# Why per-blob: FBC stores the CSV as base64 in olm.bundle.object (often with no
# olm.csv.metadata). Piping every blob through one base64 -d concatenates them
# into garbage. First blob is often a CRD, not the CSV. YAML catalogs hide the
# same blob — grep displayName: on the file finds nothing.
_csv_display_name_from_b64() {
	local decoded kind dn
	decoded=$(printf '%s' "$1" | base64 -d 2>/dev/null) || return 1
	kind=$(printf '%s' "$decoded" | jq -r '.kind // empty' 2>/dev/null || true)
	if [ "$kind" = "ClusterServiceVersion" ]; then
		dn=$(printf '%s' "$decoded" | jq -r '.spec.displayName // empty' 2>/dev/null || true)
		[ -n "$dn" ] && { printf '%s' "$dn"; return 0; }
	fi
	printf '%s' "$decoded" | grep -q '^kind: ClusterServiceVersion' || return 1
	dn=$(printf '%s' "$decoded" | awk '
		/^spec:/{s=1}
		s && /^  displayName:[[:space:]]*/ {
			sub(/^  displayName:[[:space:]]*/, "")
			print
			exit
		}')
	dn=$(_index_unquote "$dn")
	[ -n "$dn" ] && printf '%s' "$dn"
}

_display_name_from_json_file() {
	local f="$1" dn b64
	dn=$(jq -n -r 'inputs | (if type == "array" then .[] else . end) | select(.schema=="olm.bundle") | .properties[]? | select(.type=="olm.csv.metadata") | .value.displayName // empty' "$f" 2>/dev/null | grep -v '^$' | tail -1)
	[ -n "$dn" ] && { printf '%s' "$dn"; return 0; }
	while IFS= read -r b64; do
		[ -z "$b64" ] && continue
		dn=$(_csv_display_name_from_b64 "$b64") && { printf '%s' "$dn"; return 0; }
	done < <(jq -n -r 'inputs | (if type == "array" then .[] else . end) | select(.schema=="olm.bundle") | .properties[]? | select(.type=="olm.bundle.object") | .value.data // empty' "$f" 2>/dev/null)
	return 1
}

_yaml_display_name() {
	local raw
	raw=$(grep '^ *displayName:' "$1" 2>/dev/null | grep -v 'x-descriptors' | tail -1 | sed 's/.*displayName: *//')
	[ -n "$raw" ] || return 1
	_index_unquote "$raw"
}

_display_name_from_yaml_file() {
	local f="$1" dn b64
	dn=$(_yaml_display_name "$f") && { printf '%s' "$dn"; return 0; }
	while IFS= read -r b64; do
		[ -z "$b64" ] && continue
		dn=$(_csv_display_name_from_b64 "$b64") && { printf '%s' "$dn"; return 0; }
	done < <(grep -E '^[[:space:]]+data:[[:space:]]+[A-Za-z0-9+/=]+[[:space:]]*$' "$f" | awk '{print $2}')
	return 1
}

_display_name_from_bundles() {
	local search_dir="$1"
	local dn="" f
	while IFS= read -r -d '' f; do
		dn=$(_display_name_from_json_file "$f") && { echo "$dn"; return 0; }
	done < <(find "$search_dir" -name '*.json' -print0 2>/dev/null)
	while IFS= read -r -d '' f; do
		dn=$(_display_name_from_yaml_file "$f") && { echo "$dn"; return 0; }
	done < <(find "$search_dir" \( -name '*.yaml' -o -name '*.yml' \) -print0 2>/dev/null)
	echo ""
}

_extract_from_json() {
	local dir="$1" pkg_src="$2"

	local pkg="" def_ch=""
	read -r pkg def_ch < <(_jq_olm_package "$pkg_src") || true

	if [ -z "$pkg" ] || [ -z "$def_ch" ]; then
		local f
		for f in "$dir"/*.json; do
			[ -f "$f" ] || continue
			[ "$f" = "$pkg_src" ] && continue
			read -r pkg def_ch < <(_jq_olm_package "$f") || true
			[ -n "$pkg" ] && [ -n "$def_ch" ] && break
		done
	fi
	pkg=$(_index_unquote "$pkg")
	def_ch=$(_index_unquote "$def_ch")
	[ -z "$pkg" ] || [ -z "$def_ch" ] && return 1

	local display_name=""
	display_name=$(_display_name_from_json_file "$pkg_src") || true
	if [ -z "$display_name" ]; then
		display_name=$(_display_name_from_bundles "$dir")
	fi

	_index_print "$pkg" "$display_name" "$def_ch"
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
	pkg=$(_index_unquote "$pkg")
	def_ch=$(_index_unquote "$def_ch")
	[ -z "$pkg" ] || [ -z "$def_ch" ] && return 1

	local dn="" dir_path
	dir_path="$(dirname "$yf")"
	dn=$(_display_name_from_yaml_file "$yf") || true
	if [ -z "$dn" ]; then
		dn=$(_display_name_from_bundles "$dir_path")
	fi
	_index_print "$pkg" "$dn" "$def_ch"
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
