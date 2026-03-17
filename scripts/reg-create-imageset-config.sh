#!/bin/bash 
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
#   Regenerate if: ISC doesn't exist/empty OR ISC is NOT strictly newer than .created.
#   Skip if: user edited the ISC after generation (ISC is strictly newer than .created).
#   Using "! ISC -nt .created" instead of ".created -nt ISC" so that equal timestamps
#   also trigger regeneration (needed on platforms like System Z/s390x).
#   The .created file is touched at the end of each generation cycle.
#   This allows users to customize the ISC and run 'aba save' or 'aba sync' again without losing edits.
if [ ! -s data/imageset-config.yaml -o ! data/imageset-config.yaml -nt data/.created ]; then
	aba_debug "Generating new imageset-config.yaml"
	[ ! "$ocp_channel" -o ! "$ocp_version" ] && aba_abort "ocp_channel or ocp_version incorrectly defined in aba.conf"

	export ocp_ver_major=$(echo $ocp_version | cut -d. -f1-2)

	aba_info "Generating image set configuration: data/imageset-config.yaml ..."
	[ ! "$excl_platform" ] && aba_info "OpenShift platform release images for 'v$ocp_version', channel '$ocp_channel' and arch '$ARCH' ..."

	aba_debug Values: ARCH=$ARCH ocp_channel=$ocp_channel ocp_version=$ocp_version
	scripts/j2 ./templates/imageset-config.yaml.j2 > data/imageset-config.yaml
	touch data/.created  # In case next line fails!

	aba_debug "Adding operators to imageset config"
	scripts/add-operators-to-imageset.sh --output data/imageset-config.yaml
	touch data/.created  # In case next line fails!

	[ "$excl_platform" ] && sed -i -E "/ platform:/,/ graph: true/ s/^/#/" data/imageset-config.yaml && aba_debug "Excluded platform images (excl_platform=$excl_platform)"
	touch data/.created

	aba_info_ok "Image set config file created: mirror/data/imageset-config.yaml ($ocp_channel-$ocp_version $ARCH)"
	aba_info    "Reminder: Edit this file to add more content, e.g. Operators, and then run 'aba save' or 'aba sync' again."
else
	aba_debug "Using existing imageset-config.yaml (not regenerating)"
	aba_info "Using existing image set config file (data/imageset-config.yaml)"
fi
