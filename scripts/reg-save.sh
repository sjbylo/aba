#!/bin/bash 
# Save images from RH reg. to disk 

source scripts/include_all.sh

[ "$1" ] && set -x

umask 077

source <(normalize-aba-conf)

mkdir -p save

# Ensure the RH pull secrete files exist
scripts/create-containers-auth.sh

# Generate first imageset-config file for saving images.  
# Do not overwrite the file. Allow users to add images and operators to imageset-config-save.yaml and run "make save" again. 
if [ ! -s save/imageset-config-save.yaml ]; then
	rm -rf save/*

	# Check disk space under save/. 
	avail=$(df -m save | awk '{print $4}' | tail -1)

	# If less than 20 GB, stop
	if [ $avail -lt 20500 ]; then
		[ "$TERM" ] && tput setaf 1 
		echo "Error: Not enough disk space available under $PWD/save (only $avail MB). At least 20GB is required for the base OpenShift platform alone."
		[ "$TERM" ] && tput sgr0

		exit 1
	fi

	export ocp_ver=$ocp_version
	export ocp_ver_major=$(echo $ocp_version | cut -d. -f1-2)

	echo "Generating save/imageset-config-save.yaml to save images to local disk for OpenShift 'v$ocp_version' and channel '$ocp_channel' ..."
	scripts/j2 ./templates/imageset-config-save.yaml.j2 > save/imageset-config-save.yaml 
	touch save/.created
else
	# Check disk space under save/. 
	avail=$(df -m save | awk '{print $4}' | tail -1)

	# If less than 50 GB, give a warning only
	if [ $avail -lt 51250 ]; then
		[ "$TERM" ] && tput setaf 1 
		echo "Warning: Less than 50GB of space available under $PWD/save (only $avail MB). Operator images require between ~40 to ~400GB of disk space!"
		[ "$TERM" ] && tput sgr0
	fi

	echo Using existing save/imageset-config-save.yaml
	echo "Reminder: You can edit this file to add more content, e.g. Operators, and then run 'make save' again."
fi

echo 
echo "Saving images from external network to mirror/save/ directory."
echo
echo "Warning: Ensure there is enough disk space under $PWD/save.  "
echo "This can take 5-20+ mins to complete or even longer if Operator images are being saved!"
echo 

# Set up script to help for re-sync
# --continue-on-error : do not use this option. In testing the registry became unusable! 
cmd="oc mirror --config=./imageset-config-save.yaml file://."
echo "cd save && umask 0022 && $cmd" > save-mirror.sh && chmod 700 save-mirror.sh 
echo "Running $(cat save-mirror.sh)"
echo
if ! ./save-mirror.sh; then
	[ "$TERM" ] && tput setaf 1 
	echo "Warning: an error has occurred! Long running processes are prone to failure. If the error looks transient please try again!"
	[ "$TERM" ] && tput sgr0

	exit 1
fi
# If oc-mirror fails due to transient errors, the user should try again

echo
echo "==> Image saving successful"
echo 
