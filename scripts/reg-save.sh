#!/bin/bash 
# Save images from RH reg. to disk 

source scripts/include_all.sh

try_tot=1  # def. value
[ "$1" == "y" ] && set -x && shift  # If the debug flag is "y"
[ "$1" ] && [ $1 -gt 0 ] && try_tot=`expr $1 + 1` && echo "Will try $try_tot times to save the images to disk."    # If the retry value exists and it's a number

umask 077

source <(normalize-aba-conf)

# Check internet connection...
##echo_cyan -n "Checking access to https://api.openshift.com/: "
if ! curl -skIL --connect-timeout 10 --retry 3 -o "/dev/null" -w "%{http_code}\n" https://api.openshift.com/ >/dev/null; then
	echo_red "Error: Cannot access https://api.openshift.com/.  Access to the Internet is required to save the images to disk."

	exit 1
fi

mkdir -p save

# Ensure the RH pull secret files are located in the right places
scripts/create-containers-auth.sh

# Generate first imageset-config file for saving images.  
# Do not overwrite the file. Allow users to add images and operators to imageset-config-save.yaml and run "make save" again. 
if [ ! -s save/imageset-config-save.yaml ]; then
	#rm -rf save/*  # Do not do this.  There may be image set files in thie dir which are still needed. 

	# Check disk space under save/. 
	avail=$(df -m save | awk '{print $4}' | tail -1)

	# If less than 20 GB, stop
	if [ $avail -lt 20500 ]; then
		echo_red "Error: Not enough disk space available under $PWD/save (only $avail MB). At least 20GB is required for the base OpenShift platform alone."

		exit 1
	fi

	export ocp_ver=$ocp_version
	export ocp_ver_major=$(echo $ocp_version | cut -d. -f1-2)

	echo "Generating initial image set configuration: 'save/imageset-config-save.yaml' to save images to local disk for OpenShift 'v$ocp_version' and channel '$ocp_channel' ..."

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

	echo_cyan "Using existing image set config file (save/imageset-config-save.yaml)"
	echo_cyan "Reminder: You can edit this file to add more content, e.g. Operators, and then run 'make save' again to update the images."
fi

echo 
echo_cyan "Saving images from external network to mirror/save/ directory."
echo
echo_cyan "Warning: Ensure there is enough disk space under $PWD/save.  "
echo_cyan "This can take 5-20+ mins to complete or even longer if Operator images are being saved!"
echo 

# Set up script to help for re-sync
# --continue-on-error : do not use this option. In testing the registry became unusable! 
cmd="oc mirror --config=./imageset-config-save.yaml file://."
echo "cd save && umask 0022 && $cmd" > save-mirror.sh && chmod 700 save-mirror.sh 

# This loop is based on the "retry=?" value
try=1
failed=1
while [ $try -le $try_tot ]
do
	echo_magenta -n "Attempt ($try/$try_tot)."
	[ $try_tot -le 1 ] && echo_white " Set number of retries with 'make save retry=<number>'" || echo
	echo_cyan "Running: $(cat save-mirror.sh)"
	echo

	./save-mirror.sh && failed= && break

	let try=$try+1
	[ $try -le $try_tot ] && echo_magenta -n "Trying again. "
done

if [ "$failed" ]; then
	echo_red "Image saving aborted ..."
	echo_red "Warning: Long-running processes may fail. Resolve any issues if needed, otherwise, try again."

	exit 1
fi

echo_green "Images saved successfully!"
echo 
