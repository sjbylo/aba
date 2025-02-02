#!/bin/bash 
# Save images from RH reg. to disk 

source scripts/include_all.sh

# Script called with args "debug" and/or "retry"
try_tot=1  # def. value
[ "$1" == "y" ] && set -x && shift  # If the debug flag is "y"
[ "$1" ] && [ $1 -gt 0 ] && r=1 && try_tot=`expr $1 + 1` && echo "Attempting $try_tot times to save the images to disk."    # If the retry value exists and it's a number

umask 077

source <(normalize-aba-conf)

# Check internet connection...
##echo_cyan -n "Checking access to https://api.openshift.com/: "
if ! curl -skIL --connect-timeout 10 --retry 3 -o "/dev/null" -w "%{http_code}\n" https://api.openshift.com/ >/dev/null; then
	echo_red "Error: Cannot access https://api.openshift.com/.  Access to the Internet is required to save the images to disk." >&2

	exit 1
fi

# Ensure the RH pull secret files are located in the right places
scripts/create-containers-auth.sh

echo 
echo_cyan "Saving images from external network to mirror/save/ directory."
echo
echo_cyan "Warning: Ensure there is enough disk space under $PWD/save.  "
echo_cyan "This can take 5-20+ minutes to complete or even longer if Operator images are being saved!"
echo 

if [ "$oc_mirror_version" = "v1" ]; then
	# Set up script to help for re-sync
	# --continue-on-error : do not use this option. In testing the registry became unusable! 
	cmd="oc-mirror --v1 --config=imageset-config-save.yaml file://."
	echo "cd save && umask 0022 && $cmd" > save-mirror.sh && chmod 700 save-mirror.sh 
else
	cmd="oc-mirror --v2 --config=imageset-config-save.yaml file://."
	echo "cd save && $cmd" > save-mirror.sh && chmod 700 save-mirror.sh 
	# mirror-to-disk:  oc mirror -c <image_set_configuration> file://<file_path> --v2
fi

##oc mirror -c <image_set_configuration> file://<file_path> --v2

# This loop is based on the "retry=?" value
try=1
failed=1
while [ $try -le $try_tot ]
do
	echo_cyan -n "Attempt ($try/$try_tot)."
	[ $try_tot -le 1 ] && echo_white " Set number of retries with 'aba save --retry <count>'" || echo
	echo_cyan "Running: $(cat save-mirror.sh)"
	echo

	./save-mirror.sh && failed= && break

	let try=$try+1
	[ $try -le $try_tot ] && echo_red -n "Image saving failed ... Trying again. " >&2
done

if [ "$failed" ]; then
	echo_red -n "Image saving aborted ..." >&2
	[ $try_tot -gt 1 ] && echo_white " (after $try_tot/$try_tot attempts!)" || echo
	echo_red "Warning: Long-running processes sometimes fail! Resolve any issues (if needed) and try again." >&2
	echo_red "         View https://status.redhat.com/ for any current issues or planned maintenance." >&2
	[ $try_tot -eq 1 ] && echo_red "         Consider using the --retry option!" >&2

	exit 1
fi

echo
echo_green -n "Images saved successfully!"
[ $try_tot -gt 1 ] && echo_white " (after $try/$try_tot attempts!)" || echo
echo 
