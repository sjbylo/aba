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

# Ensure the RH pull secret files are located in the right places
scripts/create-containers-auth.sh

echo 
echo_cyan "Saving images from external network to mirror/save/ directory."
echo
echo_cyan "Warning: Ensure there is enough disk space under $PWD/save.  "
echo_cyan "This can take 5-20+ minutes to complete or even longer if Operator images are being saved!"
echo 

# Set up script to help for re-sync
# --continue-on-error : do not use this option. In testing the registry became unusable! 
cmd="oc-mirror --config=./imageset-config-save.yaml file://."
echo "cd save && umask 0022 && $cmd" > save-mirror.sh && chmod 700 save-mirror.sh 

# This loop is based on the "retry=?" value
try=1
failed=1
while [ $try -le $try_tot ]
do
	echo_cyan -n "Attempt ($try/$try_tot)."
	[ $try_tot -le 1 ] && echo_white " Set number of retries with 'make save retry=<number>'" || echo
	echo_cyan "Running: $(cat save-mirror.sh)"
	echo

	./save-mirror.sh && failed= && break
	# CHANGE /save-mirror.sh 2> >(tee .oc-mirror-error.log >&2) && failed= && break

	let try=$try+1
	[ $try -le $try_tot ] && echo_red -n "Image saving failed ... Trying again. "
done

if [ "$failed" ]; then
	echo_red -n "Image saving aborted ..."
	[ $try_tot -gt 1 ] && echo_white " (after $try_tot/$try_tot attempts!)" || echo
	echo_red "Warning: Long-running processes can fail! Resolve any issues (if needed) and try again."
	# CHANGE echo_red Error output:
	# CHANGE cat_red .oc-mirror-error.log

	exit 1
fi

echo
echo_green -n "Images saved successfully!"
[ $try_tot -gt 1 ] && echo_white " (after $try/$try_tot attempts!)" || echo
echo 
