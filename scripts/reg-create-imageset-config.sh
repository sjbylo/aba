#!/bin/bash
# INTENT:      Generate data/imageset-config.yaml for oc-mirror from config files
# CALLED BY:   mirror/Makefile (data/imageset-config.yaml target)
# CWD:         mirror/
# REQUIRES:    aba.conf (ocp_version, ocp_channel, op_sets, ops),
#              mirror.conf (optional ocp_version_target, op_sets/ops overrides),
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

# ISC regeneration guard:
#   Regenerate if: ISC doesn't exist/empty, OR .created is missing, OR ISC is NOT strictly newer than .created.
#   Skip if: user edited the ISC after generation (ISC is strictly newer than .created).
#   To force regeneration: rm data/.created (if .created is missing, ISC is always regenerated).
#   Using "! ISC -nt .created" instead of ".created -nt ISC" so that equal timestamps
#   also trigger regeneration (needed on platforms like System Z/s390x).
#   The .created file is touched at the end of each generation cycle.
#   This allows users to customize the ISC and run 'aba save' or 'aba sync' again without losing edits.
if [ ! -s data/imageset-config.yaml ] || [ ! -f data/.created ] || [ ! data/imageset-config.yaml -nt data/.created ]; then
	aba_debug "Generating new imageset-config.yaml"
	{ [ ! "$ocp_channel" ] || [ ! "$ocp_version" ]; } && aba_abort "ocp_channel or ocp_version incorrectly defined in aba.conf"

	export ocp_ver_major=$(echo $ocp_version | cut -d. -f1-2)

	# Upgrade mode: export target version variables for the Jinja template
	export ocp_version_target="${ocp_version_target:-}"
	export tgt_major=""
	if [ "$ocp_version_target" ] && [ "$ocp_version_target" != "$ocp_version" ]; then
		# Guard: target must be > source (upgrades only, not downgrades)
		if ! is_version_greater "$ocp_version_target" "$ocp_version"; then
			# Stale target — clear it and proceed without upgrade mode
			aba_warning "ocp_version_target ($ocp_version_target) is lower than ocp_version ($ocp_version) — ignoring."
			replace-value-conf -q -n ocp_version_target -v "" -f mirror.conf
			ocp_version_target=""
		fi
		export tgt_major=$(echo "$ocp_version_target" | cut -d. -f1-2)

		# Validate upgrade path: source version must exist in the target channel graph.
		# Covers both same-minor (z-stream) and cross-minor upgrades.
		_path_diag=""
		if _path_diag=$(verify_upgrade_path_exists "$ocp_version" "$ocp_version_target" "$ocp_channel" 2>&1); then
			: # path OK
		else
			_src="${_path_diag%%|*}"
			_rest="${_path_diag#*|}"
			_tgt_channel="${_rest%%|*}"
			_lowest="${_rest##*|}"
			aba_abort \
				"Cannot upgrade directly from $ocp_version to $ocp_version_target." \
				"Version $ocp_version is not in channel ${_tgt_channel} (lowest entry: ${_lowest:-unknown})." \
				"You need to upgrade to at least ${_lowest:-a version in ${_tgt_channel}} first." \
				"" \
				"Verify upgrade paths at: https://access.redhat.com/labs/ocpupgradegraph/update_path/"
		fi

		aba_info "Upgrade mode: $ocp_version → $ocp_version_target (channel ${ocp_channel}-${tgt_major}, shortestPath)"
	fi

	aba_info "Generating image set configuration: data/imageset-config.yaml ..."
	[ ! "$excl_platform" ] && aba_info "OpenShift platform release images for 'v$ocp_version', channel '$ocp_channel' and arch '$ARCH' ..."

	aba_debug Values: ARCH=$ARCH ocp_channel=$ocp_channel ocp_version=$ocp_version ocp_version_target=$ocp_version_target
	scripts/j2 ./templates/imageset-config.yaml.j2 > data/imageset-config.yaml
	touch data/.created  # In case next line fails!

	aba_debug "Adding operators to imageset config"
	scripts/add-operators-to-imageset.sh --output data/imageset-config.yaml
	touch data/.created  # In case next line fails!

	[ "$excl_platform" ] && sed -i -E "/ platform:/,/ graph: true/ s/^/#/" data/imageset-config.yaml && aba_debug "Excluded platform images (excl_platform=$excl_platform)"

	touch data/.created

	if [ "$tgt_major" ]; then
		aba_info_ok "Image set config file created: mirror/data/imageset-config.yaml (upgrade: $ocp_version → $ocp_version_target, $ocp_channel-$tgt_major, shortestPath, $ARCH)"
	else
		aba_info_ok "Image set config file created: mirror/data/imageset-config.yaml ($ocp_channel-$ocp_version $ARCH)"
	fi
	[ ! "$ops" ] && [ ! "$op_sets" ] && \
		aba_info "To add operators, set 'op_sets' or 'ops' in aba.conf, then re-run 'aba save' or 'aba sync'."
	aba_info "For advanced customization, edit mirror/data/imageset-config.yaml directly (your edits will be preserved)."
else
	aba_debug "Using existing imageset-config.yaml (not regenerating)"
	if [ -f ../.bundle ]; then
		if [ -f data/.isc-pinned ]; then
			aba_info "Preserving user-customized imageset-config from bundle (pinned)."
		else
			aba_info "Preserving bundled imageset-config (matches saved images). Will unlock after 'aba load'."
		fi
	else
		aba_warning "Image set config (data/imageset-config.yaml) was modified by user — preserving edits (not regenerating)." \
			"To force regeneration: rm mirror/data/.created && aba -d mirror imagesetconf"
	fi
fi
