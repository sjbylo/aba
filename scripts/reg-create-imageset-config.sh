#!/bin/bash
# INTENT:      Generate data/imageset-config.yaml for oc-mirror from config files
# CALLED BY:   mirror/Makefile (data/imageset-config.yaml target)
# CWD:         mirror/
# REQUIRES:    aba.conf (ocp_version, ocp_channel, op_sets, ops),
#              mirror.conf (optional ocp_upgrade_to, op_sets/ops overrides),
#              .index/ catalogs (for operator channel resolution)
# PRODUCES:    data/imageset-config.yaml, touches data/.created after generation
# GUARDS:
#   - Skips regeneration if ISC is strictly newer than data/.created (user/bundle ownership)
#   - In bundle mode (.bundle exists): prints info message explaining ISC is preserved
#   - In non-bundle mode: prints warning with instructions to force regeneration
# IDEMPOTENT:  Yes (same config inputs produce same ISC; user edits are preserved)
# ENV:         INFO_ABA (default: 1 when called from make)

# Generate the imageset configuration file for oc-mirror (used by save, sync, and load workflows).

# CWD is set by mirror/Makefile to the correct mirror directory

# Enable INFO messages by default when called directly from make
# (unless explicitly disabled by parent process via --quiet)
[ -z "${INFO_ABA+x}" ] && export INFO_ABA=1

source scripts/include_all.sh

[ "$1" = "-f" ] && _isc_force=$2 && shift 2

aba_debug "Starting: $0 $*"

umask 077

# aba.conf is sourced first (global defaults), then mirror.conf (per-mirror overrides).
# mirror.conf can override ops and op_sets to use different operators per mirror directory.
aba_debug "Loading configuration files"
source <(normalize-aba-conf)
source <(normalize-mirror-conf)

verify-aba-conf || aba_abort "$_ABA_CONF_ERR"
verify-mirror-conf || aba_abort "Invalid or incomplete mirror.conf. Check the errors above and fix mirror/mirror.conf."
aba_debug "Configuration validated"

# Note that any existing data/* files will not be deleted
mkdir -p data

# --- Operator resolution helpers ---

# Return 0 (true) if the display name adds information beyond the operator package name.
# Skip comments when the display name is just a reformatted version of the op name
# (e.g. web-terminal -> "Web Terminal") -- only add when genuinely different
# (e.g. cincinnati-operator -> "OpenShift Update Service").
_display_name_adds_info() {
	local op_name="$1" display_name="$2"

	local norm_op="${op_name%-operator-rh}"
	norm_op="${norm_op%-operator}"
	norm_op="${norm_op%-rh}"
	norm_op="${norm_op//-/ }"
	norm_op="${norm_op,,}"

	local norm_dn="${display_name,,}"

	local word filtered_op="" filtered_dn=""
	for word in $norm_op; do
		[[ "$word" == "operator" ]] || filtered_op+="$word "
	done
	for word in $norm_dn; do
		[[ "$word" == "operator" ]] || filtered_dn+="$word "
	done
	norm_op="${filtered_op% }"
	norm_dn="${filtered_dn% }"

	local all_found=true
	for word in $norm_op; do
		[[ "$norm_dn" != *"$word"* ]] && { all_found=false; break; }
	done
	$all_found && return 1

	all_found=true
	for word in $norm_dn; do
		[[ "$norm_op" != *"$word"* ]] && { all_found=false; break; }
	done
	$all_found && return 1

	return 0
}

# Resolve operators from op_sets and ops into JSON for the Jinja template.
# Outputs a JSON array of catalog objects on stdout.
# All user messages go to stderr.
_resolve_operators_json() {
	local catalog_ver="$1"

	# Track added operators for dedup
	declare -A _added_ops
	local _op_count=0

	# Per-catalog package lists (arrays of JSON strings)
	local _redhat_pkgs=()
	local _certified_pkgs=()
	local _community_pkgs=()

	# Special "all" operator set — mirrors entire redhat catalog
	if echo "$op_sets" | grep -qe "^all$" -e "^all," -e ",all$" -e ",all,"; then
		aba_success "Adding all redhat-operator operators to your image-set config file!" >&2
		echo '[{"catalog":"registry.redhat.io/redhat/redhat-operator-index:v'"$catalog_ver"'","all":true,"packages":[]}]'
		return 0
	fi

	# Verify catalog index files exist
	local _cat_errors=""
	for _cat in redhat-operator certified-operator community-operator; do
		if [ ! -s ".index/${_cat}-index-v${catalog_ver}" ]; then
			_cat_errors=1
			aba_warn "Missing operator catalog file: $PWD/.index/${_cat}-index-v${catalog_ver}" >&2
		fi
	done
	if [ "$_cat_errors" ]; then
		aba_abort \
			"Cannot add required operators to the image-set config file!" \
			"Your options are:" \
			"- Refresh any existing catalog files by running: 'cd $PWD; rm -f .index/redhat-operator-index-v${catalog_ver}*' and try again." \
			"- run 'cd mirror; aba catalog' to try to download the catalog file again." \
			"- Re-download the operator catalog:  aba catalog" \
			"- Check access to registry is working: 'curl -IL http://registry.redhat.io/v2'"
	fi

	# Resolve a single operator: look up in index, add to the right catalog's package list
	_resolve_op() {
		local _op="$1" _group_label="$2"
		local _index_line _op_name _op_channel _op_display

		# Skip duplicates
		[ -n "${_added_ops[$_op]+x}" ] && {
			aba_info "Operator '$_op' already added. Skipping..." >&2
			return 0
		}

		# Find which catalog contains this operator (priority: redhat, certified, community)
		local _found_cat=""
		for _cat in redhat-operator certified-operator community-operator; do
			if _index_line=$(grep "^$_op " ".index/${_cat}-index-v${catalog_ver}" 2>/dev/null); then
				_found_cat="$_cat"
				break
			fi
		done

		if [ -z "$_found_cat" ]; then
			aba_warn "Operator '$_op' (from set '$_group_label') not found in any catalog for OCP $catalog_ver -- skipping" >&2
			return 0
		fi

		_op_name=$(awk '{print $1}' <<< "$_index_line")
		_op_channel=$(awk '{print $NF}' <<< "$_index_line")
		_op_display=$(awk '{$1=""; $NF=""; gsub(/^ +| +$/, ""); print}' <<< "$_index_line")

		_added_ops["$_op"]=1
		_op_count=$(( _op_count + 1 ))

		# Build display comment
		local _comment=""
		if [ -n "$_op_display" ] && [ "$_op_display" != "-" ] && _display_name_adds_info "$_op_name" "$_op_display"; then
			_comment="$_op_display"
		fi

		# Build JSON object for this package
		local _pkg_json
		_pkg_json=$(printf '{"name":"%s","channel":"%s","comment":"%s","group":"%s"}' \
			"$_op_name" "$_op_channel" "$_comment" "$_group_label")

		# Add to the right catalog array
		case "$_found_cat" in
			redhat-operator)    _redhat_pkgs+=("$_pkg_json") ;;
			certified-operator) _certified_pkgs+=("$_pkg_json") ;;
			community-operator) _community_pkgs+=("$_pkg_json") ;;
		esac
	}

	aba_info "Adding operators to the image-set config file ..." >&2

	# Process operator sets
	for _set_name in $(echo "$op_sets" | tr "," " "); do
		if [ -s "templates/operator-set-${_set_name}" ]; then
			aba_info -n "${_set_name}: " >&2
			for _op in $(sed -e 's/#.*//' -e '/^\s*$/d' -e 's/^\s*//g' -e 's/\s*$//g' "templates/operator-set-${_set_name}"); do
				echo_white -n "$_op " >&2
				_resolve_op "$_op" "$_set_name"
			done
		else
			aba_warn \
				"Missing operator set file: 'templates/operator-set-${_set_name}'." \
				"Please adjust your operator settings (in aba.conf) or create the missing file: aba -d mirror catalog"
		fi
	done

	# Process individual operators
	if [ "$ops" ]; then
		echo >&2
		aba_info -n "misc: " >&2
		for _op in $(echo "$ops" | tr "," " "); do
			echo_white -n "$_op " >&2
			_resolve_op "$_op" "misc"
		done
	fi

	echo >&2
	aba_success "Number of operators included: $_op_count" >&2

	# Build the JSON array of catalog objects
	_build_catalog_json() {
		local _cat_name="$1" _cat_registry="$2"
		shift 2
		local _pkgs=("$@")

		[ ${#_pkgs[@]} -eq 0 ] && return

		printf '{"catalog":"%s","all":false,"packages":[' "$_cat_registry"
		local _first=true
		for _p in "${_pkgs[@]}"; do
			$_first || printf ','
			printf '%s' "$_p"
			_first=false
		done
		printf ']}'
	}

	local _catalogs=()
	local _rj _cj _cmj

	_rj=$(_build_catalog_json "redhat" "registry.redhat.io/redhat/redhat-operator-index:v${catalog_ver}" "${_redhat_pkgs[@]+"${_redhat_pkgs[@]}"}")
	[ -n "$_rj" ] && _catalogs+=("$_rj")

	_cj=$(_build_catalog_json "certified" "registry.redhat.io/redhat/certified-operator-index:v${catalog_ver}" "${_certified_pkgs[@]+"${_certified_pkgs[@]}"}")
	[ -n "$_cj" ] && _catalogs+=("$_cj")

	_cmj=$(_build_catalog_json "community" "registry.redhat.io/redhat/community-operator-index:v${catalog_ver}" "${_community_pkgs[@]+"${_community_pkgs[@]}"}")
	[ -n "$_cmj" ] && _catalogs+=("$_cmj")

	# Output final JSON array
	printf '['
	local _first=true
	for _c in "${_catalogs[@]}"; do
		$_first || printf ','
		printf '%s' "$_c"
		_first=false
	done
	printf ']'
}

# ISC regeneration guard:
#   Regenerate if: ISC doesn't exist/empty, OR .created is missing, OR ISC is NOT strictly newer than .created.
#   Skip if: user edited the ISC after generation (ISC is strictly newer than .created).
#   To force regeneration: aba --force -d mirror imagesetconf (or: rm data/.created)
#   Using "! ISC -nt .created" instead of ".created -nt ISC" so that equal timestamps
#   also trigger regeneration (needed on platforms like System Z/s390x).
#   The .created file is touched at the end of each generation cycle.
#   This allows users to customize the ISC and run 'aba save' or 'aba sync' again without losing edits.
if [ "${_isc_force:-}" != "no" ] && [ -n "${_isc_force:-}" ] || \
   [ ! -s data/imageset-config.yaml ] || [ ! -f data/.created ] || [ ! data/imageset-config.yaml -nt data/.created ]; then
	aba_debug "Generating new imageset-config.yaml"
	{ [ ! "$ocp_channel" ] || [ ! "$ocp_version" ]; } && aba_abort "ocp_channel or ocp_version incorrectly defined in aba.conf"

	export ocp_ver_major=$(echo $ocp_version | cut -d. -f1-2)

	# Upgrade mode: export target version variables for the Jinja template
	export ocp_upgrade_to="${ocp_upgrade_to:-}"
	export tgt_major=""
	if [ "$ocp_upgrade_to" ] && [ "$ocp_upgrade_to" != "$ocp_version" ]; then
		# Guard: target must be > source (upgrades only, not downgrades)
		if ! is_version_greater "$ocp_upgrade_to" "$ocp_version"; then
			# Stale target — clear it and proceed without upgrade mode
			aba_warn "ocp_upgrade_to ($ocp_upgrade_to) is lower than ocp_version ($ocp_version) — ignoring."
			replace-value-conf -q -n ocp_upgrade_to -v "" -f mirror.conf
			ocp_upgrade_to=""
		else
			export tgt_major=$(echo "$ocp_upgrade_to" | cut -d. -f1-2)

			# Validate upgrade path: source version must exist in the target channel graph.
			# Covers both same-minor (z-stream) and cross-minor upgrades.
			_path_diag=""
			if _path_diag=$(verify_upgrade_path_exists "$ocp_version" "$ocp_upgrade_to" "$ocp_channel" 2>&1); then
				: # path OK
			else
				# _path_diag is "src_ver|channel|lowest_ver" — parse pipe-delimited fields
				_src="${_path_diag%%|*}"                # first field (source version)
				_rest="${_path_diag#*|}"                # everything after first pipe
				_tgt_channel="${_rest%%|*}"             # second field (target channel)
				_lowest="${_rest##*|}"                  # last field (lowest entry point)
				aba_abort \
					"Cannot upgrade directly from $ocp_version to $ocp_upgrade_to." \
					"Version $ocp_version is not in channel ${_tgt_channel} (lowest entry: ${_lowest:-unknown})." \
					"You need to upgrade to at least ${_lowest:-a version in ${_tgt_channel}} first." \
					"" \
					"To cancel upgrade mode: aba --upgrade-to ''" \
					"Verify upgrade paths at: https://access.redhat.com/labs/ocpupgradegraph/update_path/"
			fi

			aba_info "Upgrade mode: $ocp_version → $ocp_upgrade_to (channel ${ocp_channel}-${tgt_major}, shortestPath)"
		fi
	fi

	aba_info "Generating image set configuration: data/imageset-config.yaml ..."
	[ ! "$excl_platform" ] && aba_info "OpenShift platform release images for 'v$ocp_version', channel '$ocp_channel' and arch '$ARCH' ..."

	aba_debug Values: ARCH=$ARCH ocp_channel=$ocp_channel ocp_version=$ocp_version ocp_upgrade_to=$ocp_upgrade_to

	# Resolve operators into JSON for the template
	export json_operators_data='[]'
	export has_operators=false
	_op_catalog_ver="${tgt_major:-$ocp_ver_major}"
	if [ "$ops" ] || [ "$op_sets" ]; then
		# For cross-minor upgrades, use the target version's catalog
		if [ "${tgt_major:-}" ] && [ "$tgt_major" != "$ocp_ver_major" ]; then
			aba_info "Upgrade mode: using operator catalog index v$tgt_major (target) instead of v$ocp_ver_major"
		fi
		json_operators_data=$(_resolve_operators_json "$_op_catalog_ver")
		has_operators=true
	else
		aba_info "No operators to add to the image-set config file since values ops or op_sets not defined in aba.conf or mirror.conf."
	fi

	# Atomic write: render to temp file, then move into place
	_tmp_isc=$(mktemp data/imageset-config.yaml.XXXXXX) || aba_abort "Cannot create temp file in data/"
	scripts/j2 ./templates/imageset-config.yaml.j2 > "$_tmp_isc"

	[ "$excl_platform" ] && sed -i -E "/ platform:/,/ graph: true/ s/^/#/" "$_tmp_isc" && aba_debug "Excluded platform images (excl_platform=$excl_platform)"

	mv -f "$_tmp_isc" data/imageset-config.yaml
	touch data/.created

	if [ "$tgt_major" ]; then
		aba_success "Image set config file created: mirror/data/imageset-config.yaml (upgrade: $ocp_version → $ocp_upgrade_to, $ocp_channel-$tgt_major, shortestPath, $ARCH)"
	else
		aba_success "Image set config file created: mirror/data/imageset-config.yaml ($ocp_channel-$ocp_version $ARCH)"
	fi
	[ ! "$ops" ] && [ ! "$op_sets" ] && \
		aba_info "To add operators, set 'op_sets' or 'ops' in aba.conf, then re-run 'aba save' or 'aba sync'."
	if [ ! "${_ABA_BUNDLE_MODE:-}" ]; then
		aba_info "For advanced customization, edit mirror/data/imageset-config.yaml directly (your edits will be preserved)."
	fi
else
	aba_debug "Using existing imageset-config.yaml (not regenerating)"
	if [ -f ../.bundle ]; then
		if [ -f data/.isc-pinned ]; then
			aba_info "Preserving user-customized imageset-config from bundle (pinned)."
		else
			aba_info "Preserving bundled imageset-config (matches saved images). Will unlock after 'aba load'."
		fi
	else
		aba_warn "Image set config (data/imageset-config.yaml) was modified by user — preserving edits (not regenerating)." \
			"To force regeneration: aba --force -d mirror imagesetconf"
	fi
fi
