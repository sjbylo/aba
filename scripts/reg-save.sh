#!/bin/bash
# Save images from RH reg. to disk 

# Ensure we're in mirror/ directory (script is called from mirror/Makefile)
# Use pwd -P to resolve symlinks (important when called via mirror/scripts/ symlink)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
cd "$SCRIPT_DIR/../mirror" || exit 1

# Enable INFO messages by default when called directly from make
# (unless explicitly disabled by parent process via --quiet)
[ -z "${INFO_ABA+x}" ] && export INFO_ABA=1

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

# Check internet connection...
aba_info "Checking Internet access to https://api.openshift.com/"

if ! probe_host "https://api.openshift.com/" "OpenShift API"; then
	aba_abort "Cannot access https://api.openshift.com/" \
		"Access to the Internet is required to save images to disk." \
		"Check curl error above for details."
fi

# Script called with args "debug" and/or "retry"
try_tot=1  # def. value
##[ "$1" == "y" ] && set -x && shift  # If the debug flag is "y"
[ "$1" ] && [ $1 -gt 0 ] && r=1 && try_tot=`expr $1 + 1` && aba_info "Attempting $try_tot times to save the images to disk."    # If the retry value exists and it's a number
aba_debug "try_tot=$try_tot"

umask 077

aba_debug "Loading and validating configuration"
source <(normalize-aba-conf)

verify-aba-conf || exit 1
aba_debug "Configuration validated"

# Still downloading?
export PLAIN_OUTPUT=1
aba_debug "PLAIN_OUTPUT=1 (suppressing progress indicators)"
aba_info "Ensuring CLI installation binaries are downloading"
#pwd
sleep 1
#run_once -w -i download_all_cli -- make -sC ../cli download #|| aba_abort "Downloading CLI binaries failed.  Please try again!"
# Start downloads if not already running (non-blocking, parallel)
aba_debug "Starting CLI downloads"
scripts/cli-download-all.sh

# Wait for oc-mirror specifically (needed immediately below)
aba_debug "Ensuring oc-mirror is available"
if ! ensure_oc_mirror; then
	error_msg=$(get_task_error "$TASK_OC_MIRROR")
	aba_abort "Downloading oc-mirror binary failed:\n$error_msg\n\nPlease check network and try again."
fi
aba_debug "oc-mirror is ready"


# Ensure the RH pull secret files are located in the right places
aba_debug "Creating containers auth file"
scripts/create-containers-auth.sh

# Check disk space before downloading images
aba_debug "Checking disk space in save/ directory"
mkdir -p save
avail=$(df -m save | awk '{print $4}' | tail -1)
aba_debug "Available disk space: $avail MB"

# Minimum 20GB for base platform
if [ $avail -lt 20500 ]; then
	aba_abort "Not enough disk space available under $PWD/save (only $avail MB)" \
		"At least 20GB is required for the base OpenShift platform alone" \
		"Operators require additional 40-400GB of space"
fi

# Warning for operators (if less than 50GB available)
if [ $avail -lt 51250 ]; then
	aba_warning "Less than 50GB of space available under $PWD/save (only $avail MB)" >&2
	aba_warning "Operator images require between ~40 to ~400GB of disk space!" >&2
	echo >&2
fi

aba_info "Now saving (mirror2disk) images from external network to mirror/save/ directory."

aba_warning \
	"Ensure there is enough disk space under $PWD/save." \
	"This can take 5 to 20 minutes to complete or even longer if Operator images are being saved!"
echo 

[ ! "$data_dir" ] && data_dir=\~
reg_root=$data_dir/quay-install
aba_debug "data_dir=$data_dir reg_root=$reg_root"


# reg_root now switched to data-dir. Instead of using reg_root, have data_vol=/mnt/large-disk and put all data in there? reg_root can be = $data_vol/quay-install

## If not already set, set the cache and tmp dirs to where there should be more disk space
# Had to use [[ && ]] here, as without it got "mkdir -p <missing operand>" error!
[[ ! "$TMPDIR" && "$data_dir" ]] && eval export TMPDIR=$data_dir/.tmp && eval mkdir -p $TMPDIR && aba_debug "TMPDIR=$TMPDIR"
# Note that the cache is always used except for mirror-to-mirror (sync) workflows!
# Place the '.oc-mirror/.cache' into a location where there should be more space, i.e. $data_dir, if it's defined
[[ ! "$OC_MIRROR_CACHE" && "$data_dir" ]] && eval export OC_MIRROR_CACHE=$data_dir && eval mkdir -p $OC_MIRROR_CACHE && aba_debug "OC_MIRROR_CACHE=$OC_MIRROR_CACHE"

# oc-mirror v2 tuning params
parallel_images=8
retry_delay=2
retry_times=2
image_timeout="${OC_MIRROR_IMAGE_TIMEOUT:-30m}"
aba_debug "Initial tuning: parallel_images=$parallel_images retry_delay=$retry_delay retry_times=$retry_times image_timeout=$image_timeout"

##oc mirror -c <image_set_configuration> file://<file_path> --v2

# This loop is based on the "retry=?" value
try=1
failed=1
aba_debug "Starting retry loop: try_tot=$try_tot"
while [ $try -le $try_tot ]
do
	aba_debug "Attempt $try/$try_tot: parallel_images=$parallel_images retry_delay=$retry_delay retry_times=$retry_times"
	# Set up the command in a script which can be run manually if needed.
	# --since string Include all new content since specified date (format yyyy-MM-dd). When not provided, new content since previous mirroring is mirrored (only m2d)
	cmd="oc-mirror --v2 --config=imageset-config-save.yaml file://. --since 2025-01-01  --image-timeout $image_timeout --parallel-images $parallel_images --retry-delay ${retry_delay}s --retry-times $retry_times"
	echo "cd save && umask 0022 && $cmd" > save-mirror.sh && chmod 700 save-mirror.sh
	aba_debug "Created save-mirror.sh script"

	echo
	aba_info -n "Attempt ($try/$try_tot)."
	[ $try_tot -le 1 ] && echo_white " Set number of retries with 'aba -d mirror save --retry <count>'" || echo
	aba_info "Running:"
	aba_info "$(cat save-mirror.sh)"
	echo

	# Run save command (v2 requires extra error checks)
	# v2 will return zero even if some images failed to mirror
	aba_debug "Running save-mirror.sh"
	./save-mirror.sh
	ret=$?
	aba_debug "save-mirror.sh exit code: $ret"
	#if [ $ret -eq 0 ]; then
	#if ./save-mirror.sh; then
	# Check for error files (only required for v2 of oc-mirror)
	error_file=$(ls -t save/working-dir/logs/mirroring_errors_*_*.txt 2>/dev/null | head -1)
	# Example error file:  mirroring_errors_20250914_230908.txt 
	aba_debug "error_file=${error_file:-none}"

	# v2 of oc-mirror can be in error, even if ret=0!
	if [ ! "$error_file" -a $ret -eq 0 ]; then
		aba_debug "Save completed successfully (no error file, ret=0)"
		failed=
		break    # stop the "try loop"
	fi

	if [ -s "$error_file" ]; then
		aba_debug "Error file found: $error_file - saving to save/saved_errors/"
		mkdir -p save/saved_errors
		mv $error_file save/saved_errors
		echo_red "[ABA] Error detected and log file saved in save/saved_errors/$(basename $error_file)" >&2
	fi
	#fi

	# At this point we have an error, so we adjust the tuning of v2 to reduce 'pressure' on the mirror registry
	aba_debug "Adjusting tuning parameters for next retry"
	#parallel_images=$(( parallel_images / 2 < 2 ? 2 : parallel_images / 2 ))	# half the value but it must always be at least 1
	parallel_images=$(( parallel_images - 2 < 2 ? 2 : parallel_images - 2 )) 	# Subtract 2 but never less than 2
	retry_delay=$(( retry_delay + 2 > 10 ? 10 : retry_delay + 2 )) 			# Add 2 but never more than value 10
	retry_times=$(( retry_times + 2 > 10 ? 10 : retry_times + 2 )) 			# Add 2 but never more than value 10
	aba_debug "New tuning: parallel_images=$parallel_images retry_delay=$retry_delay retry_times=$retry_times"

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
