#!/bin/bash 

source scripts/include_all.sh

[ "$1" ] && set -x

umask 077

source <(normalize-aba-conf)

mkdir -p save

# Generate first imageset-config file for saving images.  
# Do not overwrite the file. Allow users to add images and operators to imageset-config-save.yaml and run "make save" again. 
if [ ! -s save/imageset-config-save.yaml ]; then
	rm -rf save/*
	export ocp_ver=$ocp_version
	export ocp_ver_major=$(echo $ocp_version | cut -d. -f1-2)

	echo "Generating save/imageset-config-save.yaml to save images to local disk for OpenShift 'v$ocp_version' and channel '$ocp_channel' ..."
	scripts/j2 ./templates/imageset-config-save.yaml.j2 > save/imageset-config-save.yaml 
else
	# FIXME: Check here for matching varsions values in imageset config file and, if they are different, ask to 'reset' them.
	### scripts/check-version-mismatch.sh || exit 1

	echo Using existing save/imageset-config-save.yaml
	echo "Reminder: You can edit this file to add more content, e.g. Operators, and then run 'make save' again."
fi

echo 
echo "Saving images from external network to mirror/save/ directory."
echo
echo "Ensure there is enough disk space under $PWD/save.  "
echo "This can take 5-20+ mins to complete!"
echo 

# Set up script to help for re-sync
# --continue-on-error : do not use this option. In testing the registry became unusable! 
cmd="oc mirror --config=./imageset-config-save.yaml file://."
echo "cd save && umask 0022 && $cmd" > save-mirror.sh && chmod 700 save-mirror.sh 
echo "Running $(cat save-mirror.sh)"
echo
if ! ./save-mirror.sh; then
       echo "Warning: an error has occurred! If this is due to a transient error, please try again!"
       exit 1
fi
# If oc-mirror fails due to transient errors, the user should try again

