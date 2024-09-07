#!/bin/bash 
# Save images from RH reg. to disk 

source scripts/include_all.sh

try_tot=1
[ "$1" == "y" ] && set -x && shift  # If the debug flag is "y"
[ "$1" ] && [ $1 -gt 0 ] && try_tot=`expr $1 + 1` && echo "Will retry $try_tot times."    # If the retry value exists and it's a number

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
		echo_red "Error: Not enough disk space available under $PWD/save (only $avail MB). At least 20GB is required for the base OpenShift platform alone."

		exit 1
	fi

	export ocp_ver=$ocp_version
	export ocp_ver_major=$(echo $ocp_version | cut -d. -f1-2)

	echo "Generating save/imageset-config-save.yaml to save images to local disk for OpenShift 'v$ocp_version' and channel '$ocp_channel' ..."
	scripts/j2 ./templates/imageset-config-save.yaml.j2 > save/imageset-config-save.yaml 
	scripts/add-operators-to-imageset.sh >> save/imageset-config-save.yaml 
	touch save/.created
else
	# Check disk space under save/. 
	avail=$(df -m save | awk '{print $4}' | tail -1)

	# If less than 50 GB, give a warning only
	if [ $avail -lt 51250 ]; then
		echo_red "Warning: Less than 50GB of space available under $PWD/save (only $avail MB). Operator images require between ~40 to ~400GB of disk space!"
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

try=1
failed=1
while [ $try -le $try_tot ]
do
	echo_magenta -n "Attempt ($try/$try_tot)."
	[ $try_tot -le 1 ] && echo " Set number of retries with 'make save retry=<number>'" || echo
	echo "Running: $(cat save-mirror.sh)"
	echo

	./save-mirror.sh && failed= && break

	echo_red "Warning: Long-running processes may fail. Resolve any issues if needed, otherwise, try again."

	let try=$try+1
done

[ "$failed" ] && echo_red "Image saving aborted ..." && exit 1

echo
echo_green "==> Images saved successfully"
echo 
