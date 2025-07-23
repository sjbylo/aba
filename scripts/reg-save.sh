#!/bin/bash 
# Save images from RH reg. to disk 

source scripts/include_all.sh

# Script called with args "debug" and/or "retry"
try_tot=1  # def. value
[ "$1" == "y" ] && set -x && shift  # If the debug flag is "y"
[ "$1" ] && [ $1 -gt 0 ] && r=1 && try_tot=`expr $1 + 1` && echo "Attempting $try_tot times to save the images to disk."    # If the retry value exists and it's a number

umask 077

source <(normalize-aba-conf)

verify-aba-conf || exit 1

# Check internet connection...
##echo_cyan -n "Checking access to https://api.openshift.com/: "
if ! curl -skIL --connect-timeout 10 --retry 3 -o "/dev/null" -w "%{http_code}\n" https://api.openshift.com/ >/dev/null; then
	echo_red "Error: Cannot access https://api.openshift.com/.  Access to the Internet is required to save the images to disk." >&2

	exit 1
fi

# Ensure the RH pull secret files are located in the right places
scripts/create-containers-auth.sh

echo 
echo_cyan "Now saving (mirror2disk) images from external network to mirror/save/ directory."
echo
echo_cyan "Warning: Ensure there is enough disk space under $PWD/save.  "
echo_cyan "This can take 5 to 20 or more minutes to complete or even longer if Operator images are being saved!"
echo 

#FIXME: Instead of using reg_root, why not have data_vol=/mnt/large-disk and put all data in there? reg_root can be = $data_vol/quay-install
[ ! "$reg_root" ] && reg_root=$HOME/quay-install  # $reg_root is needed for TMPDIR / OC_MIRROR_CACHE below

## If not already set, set the cache and tmp dirs to where there should be more disk space
# Had to use [[ && ]] here, as without it got "mkdir -p <missing operand>" error!
[[ ! "$TMPDIR" && "$reg_root" ]] && eval export TMPDIR=$reg_root/.tmp && eval mkdir -p $TMPDIR
# Note that the cache is always used except for mirror-to-mirror (sync) workflows!
# Place the '.oc-mirror/.cache' into a location where there should be more space, i.e. $reg_root, if it's defined
[[ ! "$OC_MIRROR_CACHE" && "$reg_root" ]] && eval export OC_MIRROR_CACHE=$reg_root && eval mkdir -p $OC_MIRROR_CACHE  # This is wrong!

# oc-mirror v2 tuning params
parallel_images=8
retry_delay=2
retry_times=2

##oc mirror -c <image_set_configuration> file://<file_path> --v2

# This loop is based on the "retry=?" value
try=1
failed=1
while [ $try -le $try_tot ]
do
	# Set up the command in a script which can be run manually if needed.
	if [ "$oc_mirror_version" = "v1" ]; then
		# Set up script to help for re-sync
		# --continue-on-error : do not use this option. In testing the registry became unusable! 
		cmd="oc-mirror --v1 --config=imageset-config-save.yaml file://\$PWD"
		echo "cd save && umask 0022 && $cmd" > save-mirror.sh && chmod 700 save-mirror.sh 
	else
		cmd="oc-mirror --v2 --config=imageset-config-save.yaml file://\$PWD --parallel-images $parallel_images --retry-delay ${retry_delay}s --retry-times $retry_times"
		echo "cd save && umask 0022 && $cmd" > save-mirror.sh && chmod 700 save-mirror.sh 
	fi

	echo_cyan -n "Attempt ($try/$try_tot)."
	[ $try_tot -le 1 ] && echo_white " Set number of retries with 'aba save --retry <count>'" || echo
	echo_cyan "Running: $(cat save-mirror.sh)"
	echo

	# v1/v2 switch. For v2 need to do extra error checks!
	if [ "$oc_mirror_version" = "v1" ]; then
		./save-mirror.sh && failed= && break
	else
		# v2 will return zero even if some images failed to mirror
		if ./save-mirror.sh; then
			# Check for errors
			error_file=$(ls -t save/working-dir/logs/mirroring_errors_*_*.txt 2>/dev/null | head -1)
			if [ ! "$error_file" ]; then
				failed=
				break
			fi
			mkdir -p save/saved_errors
			cp $error_file save/saved_errors
			echo_red "Error detected and log file saved in save/saved_errors/$(basename $error_file)" >&2
		fi

		# At this point we have an error, so we adjust the tuning of v2 to reduce 'pressure' on the mirror registry
		#parallel_images=$(( parallel_images / 2 < 2 ? 2 : parallel_images / 2 ))	# half the value but it must always be at least 1
		parallel_images=$(( parallel_images - 2 < 2 ? 2 : parallel_images - 2 )) 	# Subtract 2 but never less than 2
		retry_delay=$(( retry_delay + 2 > 10 ? 10 : retry_delay + 2 )) 			# Add 2 but never more than value 10
		retry_times=$(( retry_times + 2 > 10 ? 10 : retry_times + 2 )) 			# Add 2 but never more than value 10
	fi

	let try=$try+1
	[ $try -le $try_tot ] && echo_red -n "Image saving failed ... Trying again. " >&2
done

if [ "$failed" ]; then
	echo_red -n "Image saving aborted ..." >&2
	[ $try_tot -gt 1 ] && echo_white " (after $try_tot/$try_tot attempts!)" || echo
	echo_red "Warning: Long-running processes, copying large amounts of data are prone to error! Resolve any issues (if needed) and try again." >&2
	echo_red "         View https://status.redhat.com/ for any current issues or planned maintenance." >&2
	[ $try_tot -eq 1 ] && echo_red "         Consider using the --retry option!" >&2

	exit 1
fi

echo
echo_green -n "Images saved successfully!"
[ $try_tot -gt 1 ] && echo_white " (after $try/$try_tot attempts!)" || echo
echo 
