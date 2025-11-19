#!/bin/bash 
# Save images from RH reg. to disk 

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

[ "$1" == "y" ] && set -x && shift  # If the debug flag is "y"

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

	# Check disk space under save/. 
	avail=$(df -m save | awk '{print $4}' | tail -1)
	# If this is a fresh config, then check ... if less than 20 GB, stop
	if [ $avail -lt 20500 ]; then
		aba_abort "Not enough disk space available under $PWD/save (only $avail MB). At least 20GB is required for the base OpenShift platform alone." 

		exit 1
	fi

	[ ! "$ocp_channel" -o ! "$ocp_version" ] && aba_abort "Error: ocp_channel or ocp_version incorrectly defined in aba.conf"

	export ocp_ver=$ocp_version
	export ocp_ver_major=$(echo $ocp_version | cut -d. -f1-2)

	aba_info "Generating initial image set configuration: save/imageset-config-save.yaml to save images to local disk ..."
	[ ! "$excl_platform" ] && aba_info "OpenShift platform release images for 'v$ocp_version', channel '$ocp_channel' and arch '$arch_short' ..."

	scripts/j2 ./templates/imageset-config-save-$oc_mirror_version.yaml.j2 > save/imageset-config-save.yaml 
	scripts/add-operators-to-imageset.sh >> save/imageset-config-save.yaml 

	# Uncomment the platform section
	[ "$excl_platform" ] && sed -i -E "/ platform:/,/ graph: true/ s/^/#/" save/imageset-config-save.yaml

	touch save/.created

	aba_info_ok "Image set config file created: mirror/save/imageset-config-save.yaml"
	aba_info    "Reminder: Edit this file to add more content, e.g. Operators, and then run 'aba -d mirror save' again to update the images."
else
	# Check disk space under save/. 
	avail=$(df -m save | awk '{print $4}' | tail -1)
	# If this is NOT a fresh config, then check ... if less than 50 GB, give a warning only
	if [ $avail -lt 51250 ]; then
		aba_warning "Less than 50GB of space available under $PWD/save (only $avail MB). Operator images require between ~40 to ~400GB of disk space!" >&2
	fi

	aba_info "Using existing image set config file (save/imageset-config-save.yaml)"
fi
