#!/bin/bash 
# Save images from RH reg. to disk 

# Scripts called from mirror/Makefile should cd to mirror/
# Use pwd -P to resolve symlinks (important when called via mirror/scripts/ symlink)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
cd "$SCRIPT_DIR/../mirror" || exit 1

# Enable INFO messages by default when called directly from make
# (unless explicitly disabled by parent process via --quiet)
[ -z "${INFO_ABA+x}" ] && export INFO_ABA=1

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

umask 077

source <(normalize-aba-conf)

verify-aba-conf || exit 1

# Note that any existing save/* files will not be deleted
mkdir -p save

# Ensure the RH pull secret files are located in the right places
scripts/create-containers-auth.sh

# Generate first imageset-config file for saving images.  
# Do not overwrite the file if it has been modified. Allow users to add images and operators to imageset-config-save.yaml and run "make save" again. 
if [ ! -s save/imageset-config-save.yaml -o save/.created -nt save/imageset-config-save.yaml ]; then
	#rm -rf save/*  # Do not do this.  There may be image set archive files in thie dir which are still needed. 

	[ ! "$ocp_channel" -o ! "$ocp_version" ] && aba_abort "ocp_channel or ocp_version incorrectly defined in aba.conf"

	##export ocp_ver=$ocp_version
	export ocp_ver_major=$(echo $ocp_version | cut -d. -f1-2)

	aba_info "Generating image set configuration: save/imageset-config-save.yaml to save images to local disk ..."
	[ ! "$excl_platform" ] && aba_info "OpenShift platform release images for 'v$ocp_version', channel '$ocp_channel' and arch '$ARCH' ..."

	aba_debug Values: ARCH=$ARCH ocp_channel=$ocp_channel ocp_version=$ocp_version
	scripts/j2 ./templates/imageset-config-save-v2.yaml.j2 > save/imageset-config-save.yaml
	touch save/.created  # In case next line fails!

	scripts/add-operators-to-imageset.sh --output save/imageset-config-save.yaml
	touch save/.created  # In case next line fails!

	# Uncomment the platform section
	[ "$excl_platform" ] && sed -i -E "/ platform:/,/ graph: true/ s/^/#/" save/imageset-config-save.yaml
	touch save/.created

	aba_info_ok "Image set config file created: mirror/save/imageset-config-save.yaml ($ocp_channel-$ocp_version $ARCH)"
	aba_info    "Reminder: Edit this file to add more content, e.g. Operators, and then run 'aba -d mirror save' again to update the images."
else
	aba_info "Using existing image set config file (save/imageset-config-save.yaml)"
fi
