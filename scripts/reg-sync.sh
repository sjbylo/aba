#!/bin/bash 
# Copy images from RH reg. into the registry.

# Ensure we're in mirror/ directory (script is called from mirror/Makefile)
# Use pwd -P to resolve symlinks (important when called via mirror/scripts/ symlink)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
cd "$SCRIPT_DIR/../mirror" || exit 1

# Enable INFO messages by default when called directly from make
# (unless explicitly disabled by parent process via --quiet)
[ -z "${INFO_ABA+x}" ] && export INFO_ABA=1

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

try_tot=1  # def. value
#[ "$1" == "y" ] && set -x && shift  # If the debug flag is "y"
[ "$1" ] && [ $1 -gt 0 ] && try_tot=`expr $1 + 1` && aba_info "Attempting $try_tot times to sync the images to the registry."    # If the retry value exists and it's a number
aba_debug "try_tot=$try_tot"

umask 077

aba_debug "Loading configuration files"
source <(normalize-aba-conf)
source <(normalize-mirror-conf)

verify-aba-conf || exit 1
verify-mirror-conf || exit 1
aba_debug "Configuration validated"

# Be sure a download has started ..
aba_debug "Ensuring oc-mirror is available"
if ! PLAIN_OUTPUT=1 ensure_oc_mirror; then
	error_msg=$(get_task_error "$TASK_OC_MIRROR")
	aba_abort "Downloading oc-mirror binary failed:\n$error_msg\n\nPlease check network and try again."
fi
aba_debug "oc-mirror is ready"

# This is a pull secret for RH registry
pull_secret_mirror_file=pull-secret-mirror.json
aba_debug "Checking pull secret files: $pull_secret_mirror_file or $pull_secret_file"

if [ -s $pull_secret_mirror_file ]; then
	aba_info Using $pull_secret_mirror_file ...
	aba_debug "Using mirror-specific pull secret"
elif [ -s $pull_secret_file ]; then
	aba_debug "Using default pull secret: $pull_secret_file"
	:
else
	aba_abort \
		"The pull secret file '$pull_secret_file' does not exist!" \
		"Download it from https://console.redhat.com/openshift/downloads#tool-pull-secret (select 'Tokens' in the pull-down)"
fi

# Check internet connection...
aba_info "Checking Internet access to https://api.openshift.com/"

if ! probe_host "https://api.openshift.com/" "OpenShift API"; then
	aba_abort "Cannot access https://api.openshift.com/" \
		"Access to the Internet is required to sync images to your registry." \
		"Check curl error above for details."
fi

export reg_url=https://$reg_host:$reg_port
aba_debug "reg_url=$reg_url reg_host=$reg_host reg_port=$reg_port reg_path=$reg_path"

# Adjust no_proxy if proxy is configured (duplicates are harmless for temporary export)
[ "$http_proxy" ] && export no_proxy="${no_proxy:+$no_proxy,}$reg_host" && aba_debug "Adjusted no_proxy=$no_proxy"

# Can the registry mirror already be reached?
# Support both Quay and Docker registries with different health endpoints
aba_info "Probing mirror registry at $reg_url"

if probe_host "$reg_url/health/instance" "Quay registry health endpoint"; then
	aba_debug "Quay registry detected and accessible"
elif probe_host "$reg_url/v2/" "Docker registry API"; then
	aba_debug "Docker registry detected and accessible"
elif probe_host "$reg_url/" "registry root"; then
	aba_debug "Generic registry detected and accessible"
else
	aba_abort "Cannot reach mirror registry at $reg_url" \
		"Registry must be accessible before syncing images" \
		"Tried: /health/instance (Quay), /v2/ (Docker), / (generic)" \
		"Check curl errors above for details"
fi

# This is needed since sometimes an existing registry may already be available
aba_debug "Creating containers auth file"
scripts/create-containers-auth.sh

[ ! "$data_dir" ] && data_dir=\~
reg_root=$data_dir/quay-install
aba_debug "data_dir=$data_dir reg_root=$reg_root"

###[ ! "$reg_root" ] && reg_root=$HOME/quay-install  # Needed for below TMPDIR

echo
aba_info "Now syncing (mirror2mirror) images from external network to registry $reg_host:$reg_port$reg_path. "

# Check if *aba installed Quay* (if so, show warning) or it's an existing reg. (no need to show warning)
if [ -s ./reg-uninstall.sh ]; then
	aba_warning \
		"Ensure there is enough disk space under $reg_root." \
		"This can take 5 to 20 minutes to complete or even longer if Operator images are being copied!"
fi
echo

# NOTE: that the cache is always used *except* for mirror-to-mirror (sync) workflows, where it is not used! See reg-save.sh and reg-load.sh.
# If not already set, set the cache and tmp dirs to where there should be more disk space
[[ ! "$TMPDIR" && "$data_dir" ]] && eval export TMPDIR=$data_dir/.tmp && eval mkdir -p $TMPDIR

# oc-mirror v2 tuning params
parallel_images="${OC_MIRROR_PARALLEL_IMAGES:-8}"
retry_delay=2
retry_times=2
image_timeout="${OC_MIRROR_IMAGE_TIMEOUT:-30m}"
aba_debug "Initial tuning: parallel_images=$parallel_images retry_delay=$retry_delay retry_times=$retry_times image_timeout=$image_timeout"

# This loop is based on the "retry=?" value
try=1
failed=1
aba_debug "Starting retry loop: try_tot=$try_tot"
while [ $try -le $try_tot ]
do
	aba_debug "Attempt $try/$try_tot: parallel_images=$parallel_images retry_delay=$retry_delay retry_times=$retry_times"
	# Set up the command in a script which can be run manually if needed.
	cmd="oc-mirror --v2 --config imageset-config-sync.yaml --workspace file://. docker://$reg_host:$reg_port$reg_path --image-timeout $image_timeout --parallel-images $parallel_images --retry-delay ${retry_delay}s --retry-times $retry_times"
	echo "cd sync && umask 0022 && $cmd" > sync-mirror.sh && chmod 700 sync-mirror.sh
	aba_debug "Created sync-mirror.sh script"

	echo
	aba_info -n "Attempt ($try/$try_tot)."
	[ $try_tot -le 1 ] && echo_white " Set number of retries with 'aba -d mirror sync --retry <count>'" || echo
	aba_info "Running:"
	aba_info "$(cat sync-mirror.sh)"
	echo

	###./sync-mirror.sh && failed= && break

	# Run sync command (v2 requires extra error checks)
	aba_debug "Running sync-mirror.sh"
	./sync-mirror.sh
	ret=$?
	aba_debug "sync-mirror.sh exit code: $ret"
	#if [ $ret -eq 0 ]; then
	# Check for error files (only required for v2 of oc-mirror)
	error_file=$(ls -t sync/working-dir/logs/mirroring_errors_*_*.txt 2>/dev/null | head -1)
	# Example error file:  mirroring_errors_20250914_230908.txt 
	aba_debug "error_file=${error_file:-none}"

	# v2 of oc-mirror can be in error, even if ret=0!
	if [ ! "$error_file" -a $ret -eq 0 ]; then
		aba_debug "Sync completed successfully (no error file, ret=0)"
		failed=
		break    # stop the "try loop"
	fi

	if [ -s "$error_file" ]; then
		aba_debug "Error file found: $error_file - saving to sync/saved_errors/"
		mkdir -p sync/saved_errors
		mv $error_file sync/saved_errors
		echo_red "[ABA] Error detected and log file saved in sync/saved_errors/$(basename $error_file)" >&2
	fi
	#fi

	# At this point we have an error, so we adjust the tuning of v2 to reduce 'pressure' on the mirror registry
	aba_debug "Adjusting tuning parameters for next retry"
	#parallel_images=$(( parallel_images / 2 < 1 ? 1 : parallel_images / 2 ))	# half the value but it must always be at least 1
	parallel_images=$(( parallel_images - 2 < 2 ? 2 : parallel_images - 2 )) 	# Subtract 2 but never less than 2
	retry_delay=$(( retry_delay + 2 > 10 ? 10 : retry_delay + 2 )) 			# Add 2 but never more than value 10
	retry_times=$(( retry_times + 2 > 10 ? 10 : retry_times + 2 )) 			# Add 2 but never more than value 10
	aba_debug "New tuning: parallel_images=$parallel_images retry_delay=$retry_delay retry_times=$retry_times"

	let try=$try+1
	[ $try -le $try_tot ] && echo_red -n "[ABA] Image synchronization failed ($ret) ... Trying again. "
done

if [ "$failed" ]; then
	let try=$try-1
	aba_warning -n "Image synchronization aborted ..."
	[ $try_tot -gt 1 ] && echo_white " (after $try/$try_tot attempts!)" || echo
	aba_warning \
		"Long-running processes, copying large amounts of data are prone to error! Resolve any issues (if needed) and try again." \
		"View https://status.redhat.com/ for any current issues or planned maintenance." 
	[ $try_tot -eq 1 ] && echo_red "         Consider using the --retry option!" >&2

	exit 1
fi

echo
aba_info_ok -n "Images synchronized successfully!"
[ $try_tot -gt 1 -a $try -gt 1 ] && echo_white " (after $try attempts!)" || echo   # Show if more than 1 attempt

echo 
aba_info_ok "OpenShift can now be installed. From aba's top-level directory, run the command:"
aba_info_ok "  aba cluster --name mycluster [--type <sno|compact|standard>] [--starting-ip <ip>] [--api-vip <ip>] [--ingress-vip <ip>]"
aba_info_ok "Run 'aba cluster --help' for more information about installing clusters."

echo
if have_installed_clusters=$(echo ../*/.install-complete) && [ "$have_installed_clusters" != "../*/.install-complete" ]; then
	aba_warning -c magenta -p IMPORANT \
		"If you have already installed a cluster, (re-)run the command 'aba -d <clustername> day2'" \
		"to configure/refresh OperatorHub/Catalogs, Signatures etc."
	echo
fi

exit 0
