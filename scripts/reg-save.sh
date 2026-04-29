#!/bin/bash
# Save images from RH reg. to disk 

# CWD is set by mirror/Makefile to the correct mirror directory

# Enable INFO messages by default when called directly from make
# (unless explicitly disabled by parent process via --quiet)
[ -z "${INFO_ABA+x}" ] && export INFO_ABA=1

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

# Check internet connection to the registries oc-mirror pulls from
aba_info "Checking Internet access to registry.redhat.io"

if ! curl -sILk --connect-timeout 10 --max-time 15 --retry 2 https://registry.redhat.io/v2/ >/dev/null 2>&1; then
	aba_abort "Cannot access https://registry.redhat.io/" \
		"Access to registry.redhat.io is required to save images to disk."
fi

# Script called with args "debug" and/or "retry"
try_tot=1  # def. value
##[ "$1" == "y" ] && set -x && shift  # If the debug flag is "y"
[ "$1" ] && [ $1 -gt 0 ] && r=1 && try_tot=`expr $1 + 1` && aba_info "Attempting $try_tot times to save the images to disk."    # If the retry value exists and it's a number
aba_debug "try_tot=$try_tot"

umask 077

aba_debug "Loading and validating configuration"
source <(normalize-aba-conf)
source <(normalize-mirror-conf)

verify-aba-conf || aba_abort "$_ABA_CONF_ERR"
aba_debug "Configuration validated"

# Still downloading?
export PLAIN_OUTPUT=1
aba_debug "PLAIN_OUTPUT=1 (suppressing progress indicators)"
aba_info "Ensuring CLI installation binaries are available"
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
scripts/create-containers-auth.sh || exit 1

# Check disk space before downloading images
aba_debug "Checking disk space in data/ directory"
mkdir -p data
avail=$(df -m data | awk '{print $4}' | tail -1)
aba_debug "Available disk space: $avail MB"

# Minimum 20GB for base platform
if [ $avail -lt 20500 ]; then
	aba_abort "Not enough disk space available under $PWD/data (only $avail MB)" \
		"At least 20GB is required for the base OpenShift platform alone" \
		"Operators require additional 40-400GB of space"
fi

# Warning for operators (if less than 50GB available)
if [ $avail -lt 51250 ]; then
	aba_warning "Less than 50GB of space available under $PWD/data (only $avail MB)" >&2
	aba_warning "Operator images require between ~40 to ~400GB of disk space!" >&2
	echo >&2
fi

aba_info "Now saving (mirror2disk) images from external network to mirror/data/ directory."

aba_warning \
	"Ensure there is enough disk space under $PWD/data." \
	"This can take 5 to 20 minutes to complete or even longer if Operator images are being saved!"
echo 

[ ! "$data_dir" ] && data_dir=\~
reg_root=$data_dir/quay-install
aba_debug "data_dir=$data_dir reg_root=$reg_root"


# reg_root now switched to data-dir. Instead of using reg_root, have data_vol=/mnt/large-disk and put all data in there? reg_root can be = $data_vol/quay-install

## Set TMPDIR and OC_MIRROR_CACHE paths (defer mkdir to just before oc-mirror needs them)
# Had to use [[ && ]] here, as without it got "mkdir -p <missing operand>" error!
[[ ! "$TMPDIR" && "$data_dir" ]] && eval export TMPDIR=$data_dir/.tmp && aba_debug "TMPDIR=$TMPDIR"
# Note that the cache is always used except for mirror-to-mirror (sync) workflows!
# Place the '.oc-mirror/.cache' into a location where there should be more space, i.e. $data_dir, if it's defined
[[ ! "$OC_MIRROR_CACHE" && "$data_dir" ]] && eval export OC_MIRROR_CACHE=$data_dir && aba_debug "OC_MIRROR_CACHE=$OC_MIRROR_CACHE"

# Build the base oc-mirror command. --since is only relevant for save (mirror-to-disk).
# When OC_MIRROR_SINCE is set (e.g. "2020-01-01"), archives include all content since that
# date -- use a far-back date to force a complete archive every time. When unset (default),
# oc-mirror creates differential archives (only new blobs since the last save).
# --v2 is an oc-mirror CLI flag (not related to OCP version). May become default in future releases.
base_cmd="oc-mirror --v2 --config imageset-config.yaml file://. ${OC_MIRROR_SINCE:+--since $OC_MIRROR_SINCE}"

[ "$TMPDIR" ] && eval mkdir -p "$TMPDIR"
[ "$OC_MIRROR_CACHE" ] && eval mkdir -p "$OC_MIRROR_CACHE"

if ! _run_oc_mirror_with_retry "save" "$try_tot" "$base_cmd"; then
	exit 1
fi

echo
aba_info_ok "Use 'aba tar --out /path/to/large/portable/media/install-bundle.tar' to create an install bundle which can be transferred to your disconnected environment."
aba_info_ok "In your disconnected environment, unpack the install bundle and run 'cd aba; ./install; aba' for further instructions."
echo

exit 0
