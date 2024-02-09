#!/bin/bash 

source scripts/include_all.sh

[ "$1" ] && set -x

umask 077

source <(normalize-aba-conf)
source <(normalize-mirror-conf)

mkdir -p save

# Generate first imageset-config file for saving images.  
# Do not overwrite the file. Allow users to add images and operators to imageset-config-save.yaml and run "make save" again. 
if [ ! -s save/imageset-config-save.yaml ]; then
	export ocp_ver=$ocp_version
	export ocp_ver_major=$(echo $ocp_version | cut -d. -f1-2)

	echo Generating save/imageset-config-save.yaml to save images to local disk for v$ocp_version and channel $ocp_channel ...
	scripts/j2 ./templates/imageset-config-save.yaml.j2 > save/imageset-config-save.yaml 
else
	echo Using existing save/imageset-config-save.yaml
	echo "Reminder: You can edit this file to add more content, e.g. Operators, and then run 'make save' again."
fi

echo 
echo "Saving images from the external network (Internet) to mirror/save/."
echo "Ensure there is enough disk space under $PWD/save.  "
echo "This can take 5-20+ mins to complete!"
echo 

# Set up script to help for manual re-sync
# --continue-on-error  needed when mirroring operator images
echo "cd save && oc mirror --continue-on-error --config=./imageset-config-save.yaml file://." > save-mirror.sh && chmod 700 save-mirror.sh 
cat ./save-mirror.sh

# rm -rf save/   # Allow user to add more image sets (e.g. for adding operators or image updates) to the archive 

./save-mirror.sh

