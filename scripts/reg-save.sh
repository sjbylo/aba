#!/bin/bash -e
# Save images from RH reg. to disk 

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

# Check internet connection...
##aba_info -n "Checking access to https://api.openshift.com/: "
if ! curl -skIL --connect-timeout 10 --retry 8 -o "/dev/null" -w "%{http_code}\n" https://api.openshift.com/ >/dev/null; then
	aba_abort "Error: Cannot access https://api.openshift.com/.  Access to the Internet is required to save the images to disk." 
fi

# Script called with args "debug" and/or "retry"
try_tot=1  # def. value
##[ "$1" == "y" ] && set -x && shift  # If the debug flag is "y"
[ "$1" ] && [ $1 -gt 0 ] && r=1 && try_tot=`expr $1 + 1` && aba_info "Attempting $try_tot times to save the images to disk."    # If the retry value exists and it's a number

umask 077

source <(normalize-aba-conf)

verify-aba-conf || exit 1

# Still downloading?
export PLAIN_OUTPUT=1
aba_info "Downloading CLI installation binaries"
#echo ABA_ROOT=$ABA_ROOT
#pwd
sleep 1
#run_once -w -i download_all_cli -- make -sC ../cli download #|| aba_abort "Downloading CLI binaries failed.  Please try again!"
scripts/cli-download-all.sh --wait

aba_info_ok "CLI Installation binaries downloaded successfully!"

aba_info "Checking for oc-mirror binary."
run_once -w -i cli:install:oc-mirror -- make -sC $ABA_ROOT/cli oc-mirror || aba_abort "Downloading oc-mirror binary failed.  Please try again!"


# Ensure the RH pull secret files are located in the right places
scripts/create-containers-auth.sh

aba_info "Now saving (mirror2disk) images from external network to mirror/save/ directory."

aba_warning \
	"Ensure there is enough disk space under $PWD/save." \
	"This can take 5 to 20 minutes to complete or even longer if Operator images are being saved!"
echo 

[ ! "$data_dir" ] && data_dir=\~
reg_root=$data_dir/quay-install


# reg_root now switched to data-dir. Instead of using reg_root, have data_vol=/mnt/large-disk and put all data in there? reg_root can be = $data_vol/quay-install

## If not already set, set the cache and tmp dirs to where there should be more disk space
# Had to use [[ && ]] here, as without it got "mkdir -p <missing operand>" error!
[[ ! "$TMPDIR" && "$data_dir" ]] && eval export TMPDIR=$data_dir/.tmp && eval mkdir -p $TMPDIR
# Note that the cache is always used except for mirror-to-mirror (sync) workflows!
# Place the '.oc-mirror/.cache' into a location where there should be more space, i.e. $data_dir, if it's defined
[[ ! "$OC_MIRROR_CACHE" && "$data_dir" ]] && eval export OC_MIRROR_CACHE=$data_dir && eval mkdir -p $OC_MIRROR_CACHE

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
		cmd="oc-mirror --v1 --config=imageset-config-save.yaml file://."
		echo "cd save && umask 0022 && $cmd" > save-mirror.sh && chmod 700 save-mirror.sh 
	else
		# --since string Include all new content since specified date (format yyyy-MM-dd). When not provided, new content since previous mirroring is mirrored (only m2d)
		#cmd="oc-mirror --v2 --config=imageset-config-save.yaml file://. --since 2025-01-01                     --parallel-images $parallel_images --retry-delay ${retry_delay}s --retry-times $retry_times"
		# Wait for oc-mirror to be available!
		##run_once -w -i cli:install:oc-mirror -- make -sC $ABA_ROOT/cli oc-mirror 
		cmd="oc-mirror --v2 --config=imageset-config-save.yaml file://. --since 2025-01-01  --image-timeout 15m --parallel-images $parallel_images --retry-delay ${retry_delay}s --retry-times $retry_times"
		echo "cd save && umask 0022 && $cmd" > save-mirror.sh && chmod 700 save-mirror.sh 
	fi

	echo
	aba_info -n "Attempt ($try/$try_tot)."
	[ $try_tot -le 1 ] && echo_white " Set number of retries with 'aba -d mirror save --retry <count>'" || echo
	aba_info "Running:"
	aba_info "$(cat save-mirror.sh)"
	echo

	# v1/v2 switch. For v2 need to do extra error checks!
	if [ "$oc_mirror_version" = "v1" ]; then
		./save-mirror.sh && failed= && break || ret=$?
	else
		# v2 will return zero even if some images failed to mirror
		./save-mirror.sh
		ret=$?
		#if [ $ret -eq 0 ]; then
		#if ./save-mirror.sh; then
			# Check for error files (only required for v2 of oc-mirror)
			error_file=$(ls -t save/working-dir/logs/mirroring_errors_*_*.txt 2>/dev/null | head -1)
			# Example error file:  mirroring_errors_20250914_230908.txt 

			# v2 of oc-mirror can be in error, even if ret=0!
			if [ ! "$error_file" -a $ret -eq 0 ]; then
				failed=
				break    # stop the "try loop"
			fi

			if [ -s "$error_file" ]; then
				mkdir -p save/saved_errors
				cp $error_file save/saved_errors
				echo_red "[ABA] Error detected and log file saved in save/saved_errors/$(basename $error_file)" >&2
			fi
		#fi

		# At this point we have an error, so we adjust the tuning of v2 to reduce 'pressure' on the mirror registry
		#parallel_images=$(( parallel_images / 2 < 2 ? 2 : parallel_images / 2 ))	# half the value but it must always be at least 1
		parallel_images=$(( parallel_images - 2 < 2 ? 2 : parallel_images - 2 )) 	# Subtract 2 but never less than 2
		retry_delay=$(( retry_delay + 2 > 10 ? 10 : retry_delay + 2 )) 			# Add 2 but never more than value 10
		retry_times=$(( retry_times + 2 > 10 ? 10 : retry_times + 2 )) 			# Add 2 but never more than value 10
	fi

	let try=$try+1
	[ $try -le $try_tot ] && echo_red -n "[ABA] Image saving failed ($ret) ... Trying again. " >&2
done

if [ "$failed" ]; then
	let try=$try-1
	aba_warning -n "Image saving aborted ..." >&2
	[ $try_tot -gt 1 ] && aba_info " (after $try/$try_tot attempts!)" || echo
	aba_warning \
		"Long-running processes, copying large amounts of data are prone to error! Resolve any issues (if needed) and try again." \
		"View https://status.redhat.com/ for any current issues or planned maintenance." 
	[ $try_tot -eq 1 ] && echo_red "         Consider using the --retry option!" >&2

	exit 1
fi

echo
aba_info_ok -n "Images saved successfully!"
[ $try_tot -gt 1 -a $try -gt 1 ] && aba_info " (after $try attempts!)" || echo   # Show if more than 1 attempt
echo 

aba_info_ok "Use 'aba tar --out /path/to/large/portable/media/install-bundle.tar' to create an install bundle which can be transferred to your disconnected environment."
aba_info_ok "In your disconnected environment, unpack the install bundle and run 'cd aba; ./install; aba' for further instructions."
echo

exit 0
