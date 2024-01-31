#!/bin/bash 

. scripts/include_all.sh

[ "$1" ] && set -x

umask 077

source mirror.conf

# Generate first imageset-config file for saving images.  
# Do not overwrite the file. Allow users to add images and operators to imageset-config-save.yaml and run "make save" again. 
if [ ! -s imageset-config-save.yaml ]; then
	export ocp_ver=$ocp_target_ver
	export ocp_ver_major=$(echo $ocp_target_ver | cut -d. -f1-2)

	echo Generating imageset-config-save.yaml to save images to local disk ...
	scripts/j2 ./templates/imageset-config-save.yaml.j2 > imageset-config-save.yaml 
	#scripts/j2 ./templates/imageset-config.yaml.j2 > imageset-config.yaml 
else
	echo Using existing imageset-config-save.yaml
	#echo Using existing imageset-config.yaml
fi

echo 
echo "Saving images from the external network (Internet) to mirror/save/."
echo "Ensure there is enough disk space under $PWD/save.  "
echo "This can take 10-20 mins to complete!"
echo 

# Set up script to help for manual re-sync
echo "oc mirror --config=./imageset-config-save.yaml file://save" > save-mirror.sh && chmod 700 save-mirror.sh 
#echo "oc mirror --config=./imageset-config.yaml file://save" > save-mirror.sh && chmod 700 save-mirror.sh 
cat ./save-mirror.sh

##### rm -rf save/   # Allow user to add more image sets (e.g. for adding operators or image updates) to the archive 

./save-mirror.sh

