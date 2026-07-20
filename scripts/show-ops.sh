#!/bin/bash
# show-ops.sh -- List available operators from catalog indexes
#
# INTENT:    Display operators from .index/ (refreshed) or catalogs/ (shipped),
#            with optional catalog filtering and refresh.
# CALLED BY: aba show-ops (via aba.sh)
# CWD:       ABA repo root
# REQUIRES:  aba.conf (ocp_version)
# ARGS:      [--certified] [--community] [--redhat] [--all] [--refresh]

set -eo pipefail

source scripts/include_all.sh
source <(normalize-aba-conf)

# --- Parse arguments ---

_catalogs=()
_refresh=""

while [ "$#" -gt 0 ]; do
	case "$1" in
		--certified) _catalogs+=(certified-operator); shift ;;
		--community) _catalogs+=(community-operator); shift ;;
		--redhat)    _catalogs+=(redhat-operator); shift ;;
		--all)       _catalogs=(redhat-operator certified-operator community-operator); shift ;;
		--refresh)   _refresh=1; shift ;;
		*) aba_abort "Unknown option '$1'. Usage: aba show-ops [--certified] [--community] [--redhat] [--all] [--refresh]" ;;
	esac
done

[ ${#_catalogs[@]} -eq 0 ] && _catalogs=(redhat-operator)

# --- Resolve OCP version ---

_ocp_major=$(echo "$ocp_version" | cut -d. -f1-2)
[ -z "$_ocp_major" ] && aba_abort "No ocp_version set. Run 'aba' first or set ocp_version in aba.conf."

# --- Refresh catalogs if requested ---

if [ "$_refresh" ]; then
	aba_info "Refreshing operator catalogs for v${_ocp_major} ..." >&2
	download_all_catalogs "$_ocp_major"
	wait_for_all_catalogs "$_ocp_major"
	aba_info "Catalog refresh complete." >&2
fi

# Populate .index/ from shipped catalogs if live versions don't exist
_populate_shipped_indexes

# --- Column widths ---

_op_width=48
_desc_width=52

# Truncate a string to a max length, appending ".." if truncated
_trunc() {
	local s="$1" max="$2"
	if [ ${#s} -gt $max ]; then
		echo "${s:0:$(( max - 2 ))}.."
	else
		echo "$s"
	fi
}

# --- Display ---

_show_all=""
[ ${#_catalogs[@]} -gt 1 ] && _show_all=1

if [ "$_show_all" ]; then
	printf "  %-14s %-${_op_width}s %-${_desc_width}s %s\n" "CATALOG" "OPERATOR" "DESCRIPTION" "DEFAULT CHANNEL"
	printf "  %-14s %-${_op_width}s %-${_desc_width}s %s\n" "-------" "--------" "-----------" "---------------"
else
	printf "  %-${_op_width}s %-${_desc_width}s %s\n" "OPERATOR" "DESCRIPTION" "DEFAULT CHANNEL"
	printf "  %-${_op_width}s %-${_desc_width}s %s\n" "--------" "-----------" "---------------"
fi

for _cat in "${_catalogs[@]}"; do
	_idx_file=""
	# Prefer .index/ (refreshed) over catalogs/ (shipped)
	[ -s ".index/${_cat}-index-v${_ocp_major}" ] && _idx_file=".index/${_cat}-index-v${_ocp_major}"
	[ -z "$_idx_file" ] && [ -s "catalogs/${_cat}-index-v${_ocp_major}" ] && _idx_file="catalogs/${_cat}-index-v${_ocp_major}"
	if [ -z "$_idx_file" ]; then
		aba_info "Downloading ${_cat} catalog for v${_ocp_major} ..." >&2
		download_all_catalogs "$_ocp_major"
		wait_for_all_catalogs "$_ocp_major"
		[ -s ".index/${_cat}-index-v${_ocp_major}" ] && _idx_file=".index/${_cat}-index-v${_ocp_major}"
	fi
	if [ -z "$_idx_file" ]; then
		aba_warn "No catalog data available for ${_cat} v${_ocp_major}" >&2
		continue
	fi

	_cat_label="${_cat%-operator}"
	while read -r _line; do
		[ -z "$_line" ] && continue
		_op="${_line%% *}"
		_chan="${_line##* }"
		_desc="${_line#$_op}"
		_desc="${_desc%$_chan}"
		_desc="${_desc#"${_desc%%[![:space:]]*}"}"
		_desc="${_desc%"${_desc##*[![:space:]]}"}"
		[ -z "$_op" ] && continue

		_desc=$(_trunc "$_desc" $_desc_width)

		if [ "$_show_all" ]; then
			printf "  %-14s %-${_op_width}s %-${_desc_width}s %s\n" "$_cat_label" "$_op" "$_desc" "$_chan"
		else
			printf "  %-${_op_width}s %-${_desc_width}s %s\n" "$_op" "$_desc" "$_chan"
		fi
	done < "$_idx_file"
done
