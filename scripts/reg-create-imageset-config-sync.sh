#!/bin/bash 
# Copy images from RH reg. into the registry.

# CWD is set by mirror/Makefile to the correct mirror directory

# Enable INFO messages by default when called directly from make
# (unless explicitly disabled by parent process via --quiet)
[ -z "${INFO_ABA+x}" ] && export INFO_ABA=1

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

umask 077

aba_debug "Loading configuration files"
source <(normalize-aba-conf)
source <(normalize-mirror-conf)
export regcreds_dir=$HOME/.aba/mirror/$(basename "$PWD")

verify-aba-conf || aba_abort "$_ABA_CONF_ERR"
verify-mirror-conf || aba_abort "Invalid or incomplete mirror.conf. Check the errors above and fix mirror/mirror.conf."
aba_debug "Configuration validated"

export reg_url=https://$reg_host:$reg_port
aba_debug "reg_url=$reg_url reg_host=$reg_host reg_port=$reg_port"

# FIXME: PROBE NOT NEEDED HERE?!
## Can the registry mirror already be reached?
#[ "$http_proxy" ] && echo "$no_proxy" | grep -q "\b$reg_host\b" || no_proxy=$no_proxy,$reg_host			  # adjust if proxy in use
#aba_info "Probing mirror registry at $reg_url/health/instance"
#
#if ! probe_host "$reg_url/health/instance" "mirror registry"; then
#	aba_abort "Cannot reach mirror registry at $reg_url/health/instance" \
#		"Registry must be accessible before creating ImageSet config" \
#		"Check curl error above for details"
#fi
# FIXME: PROBE NOT NEEDED HERE?!

# Note that any existing sync/* files will not be deleted
aba_debug "Creating sync/ directory"
mkdir -p sync 

# ISC regeneration guard:
#   Regenerate if: ISC doesn't exist/empty OR .created marker is newer than ISC.
#   Skip if: user edited the ISC after generation (ISC is newer than .created).
#   The .created file is touched at the end of each generation cycle.
#   This allows users to customize the ISC and run 'aba sync' again without losing edits.
if [ ! -s sync/imageset-config-sync.yaml -o sync/.created -nt sync/imageset-config-sync.yaml ]; then
	aba_debug "Generating new imageset-config-sync.yaml"
	[ ! "$ocp_channel" -o ! "$ocp_version" ] && aba_abort "ocp_channel or ocp_version incorrectly defined in aba.conf"

	#export ocp_ver=$ocp_version
	export ocp_ver_major=$(echo $ocp_version | cut -d. -f1-2)

	aba_info "Generating image set configuration: sync/imageset-config-sync.yaml to sync images to the mirror registry ..."
	[ ! "$excl_platform" ] && aba_info "OpenShift platform release images for 'v$ocp_version', channel '$ocp_channel' and arch '$ARCH' ..."

	[ ! "$ocp_channel" -o ! "$ocp_version" ] && aba_abort "ocp_channel or ocp_version incorrectly defined in aba.conf" 

	aba_debug Values: ARCH=$ARCH ocp_channel=$ocp_channel ocp_version=$ocp_version
	aba_debug "Rendering imageset-config-sync.yaml from template"
	scripts/j2 ./templates/imageset-config-sync-v2.yaml.j2 > sync/imageset-config-sync.yaml 
	touch sync/.created # In case next line fails!

	aba_debug "Adding operators to imageset config"
	scripts/add-operators-to-imageset.sh --output sync/imageset-config-sync.yaml
	touch sync/.created # In case next line fails!

	[ "$excl_platform" ] && sed -i -E "/ platform:/,/ graph: true/ s/^/#/" sync/imageset-config-sync.yaml && aba_debug "Excluded platform images (excl_platform=$excl_platform)"
	touch sync/.created

	aba_info_ok "Image set config file created: mirror/sync/imageset-config-sync.yaml ($ocp_channel-$ocp_version $ARCH)"
	aba_info    "Reminder: Edit this file to add more content, e.g. Operators, and then run 'aba -d mirror sync' again."
else
	aba_debug "Using existing imageset-config-sync.yaml (not regenerating)"
	aba_info "Using existing image set config file (save/imageset-config-sync.yaml)"
fi

# This is needed since sometimes an existing registry may already be available
aba_debug "Creating containers auth file"
scripts/create-containers-auth.sh || exit 1

