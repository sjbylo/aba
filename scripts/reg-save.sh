#!/bin/bash
# Save images from RH reg. to disk 

# CWD is set by mirror/Makefile to the correct mirror directory

# Enable INFO messages by default when called directly from make
# (unless explicitly disabled by parent process via --quiet)
[ -z "${INFO_ABA+x}" ] && export INFO_ABA=1

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

# Script called with args "debug" and/or "retry"
try_tot=1  # def. value
##[ "$1" == "y" ] && set -x && shift  # If the debug flag is "y"
[ "$1" ] && [ $1 -gt 0 ] && r=1 && try_tot=$(( $1 + 1 )) && aba_info "Attempting $try_tot times to save the images to disk."    # If the retry value exists and it's a number
aba_debug "try_tot=$try_tot"

umask 077

aba_debug "Loading and validating configuration"
source <(normalize-aba-conf)
source <(normalize-mirror-conf)

verify-aba-conf || aba_abort "$_ABA_CONF_ERR"
aba_debug "Configuration validated"

# Pre-flight: verify internet access and pull secret before proceeding
require_internet_and_pull_secret

# Pre-flight: verify release version(s) exist in Cincinnati graph before running oc-mirror
aba_info "Verifying release image availability for v${ocp_version} ..."
if ! verify_release_version_exists "$ocp_version"; then
	aba_abort \
		"Release version $ocp_version not found in '${ocp_channel}' channel (arch: ${ARCH:-amd64})." \
		"This version may not have been released yet, or the channel may be wrong." \
		"Use 'aba ocp-versions' to list available versions."
fi
if [ "${ocp_upgrade_to:-}" ] && [ "$ocp_upgrade_to" != "$ocp_version" ]; then
	aba_info "Verifying release image availability for upgrade target v${ocp_upgrade_to} ..."
	if ! verify_release_version_exists "$ocp_upgrade_to"; then
		aba_abort \
			"Upgrade target version $ocp_upgrade_to not found in '${ocp_channel}' channel (arch: ${ARCH:-amd64})." \
			"This version may not have been released yet, or the channel may be wrong." \
			"Use 'aba ocp-versions' to list available versions."
	fi
	# Fail fast: verify upgrade path exists before starting downloads
	_path_diag=""
	if ! _path_diag=$(verify_upgrade_path_exists "$ocp_version" "$ocp_upgrade_to" "$ocp_channel" 2>&1); then
		_tgt_ch="${_path_diag#*|}" && _tgt_ch="${_tgt_ch%%|*}"   # middle field (target channel)
		_lowest="${_path_diag##*|}"                              # last field (lowest entry point)
		aba_abort \
			"Cannot upgrade directly from $ocp_version to $ocp_upgrade_to." \
			"Version $ocp_version is not in channel ${_tgt_ch} (lowest entry: ${_lowest:-unknown})." \
			"You need to upgrade to at least ${_lowest:-a version in ${_tgt_ch}} first." \
			"" \
			"Verify upgrade paths at: https://access.redhat.com/labs/ocpupgradegraph/update_path/"
	fi

	# Auto-fix: upgrade requires release images — excl_platform=true would omit them
	if [ "${excl_platform:-}" = "true" ]; then
		aba_warn "Upgrade target set (${ocp_upgrade_to}) but excl_platform=true — release images would be missing." \
			"Switching excl_platform=false in aba.conf to include release images."
		replace-value-conf -n excl_platform -v "false" -f "$ABA_ROOT/aba.conf"
		excl_platform=false
	fi
fi

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

# Also download CLIs for the upgrade version (needed on disconnected host)
if [ "${ocp_upgrade_to:-}" ] && [ "$ocp_upgrade_to" != "$ocp_version" ]; then
	aba_info "Downloading CLI binaries for upgrade version $ocp_upgrade_to ..."
	scripts/cli-download-all.sh --upgrade-to "$ocp_upgrade_to"
fi

# Re-enable colored output now that CLI downloads are done.
# In bundle mode (_ABA_BUNDLE_MODE), keep PLAIN_OUTPUT as an extra safety layer
# to prevent color escape codes from reaching the tar stream (the primary guards
# are make-bundle.sh's >&2 redirect and _print_colored's [ -t 1 ] check).
[ ! "${_ABA_BUNDLE_MODE:-}" ] && unset PLAIN_OUTPUT

# Wait for oc-mirror specifically (needed immediately below)
aba_debug "Ensuring oc-mirror is available"
if ! ensure_oc_mirror; then
	error_msg=$(get_task_error "$TASK_INST_OC_MIRROR")
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

# Stark warning if very low (incremental saves may still succeed, so don't abort)
if [ $avail -lt 20500 ]; then
	aba_warn "Very low disk space under $PWD/data (only $avail MB free)" \
		"A first-time save requires at least 20GB for the base platform alone" \
		"Operators require additional 40-400GB of space" \
		"Incremental saves may succeed with less space"
	echo >&2
elif [ $avail -lt 51250 ]; then
	aba_warn "Less than 50GB of space available under $PWD/data (only $avail MB)" \
		"Operator images require between ~40 to ~400GB of disk space!"
	echo >&2
fi

aba_info "Using oc-mirror version $(oc_mirror_version)"
aba_info "Now saving (mirror2disk) images from external network to mirror/data/ directory."

aba_warn \
	"Ensure there is enough disk space under $PWD/data." \
	"This can take 5 to 20 minutes to complete or even longer if Operator images are being saved!"
echo >&2

[ ! "$data_dir" ] && data_dir=\~
reg_root=$data_dir/quay-install
aba_debug "data_dir=$data_dir reg_root=$reg_root"


# reg_root now switched to data-dir. Instead of using reg_root, have data_vol=/mnt/large-disk and put all data in there? reg_root can be = $data_vol/quay-install

## Set TMPDIR and OC_MIRROR_CACHE paths (defer mkdir to just before oc-mirror needs them)
# Had to use [[ && ]] here, as without it got "mkdir -p <missing operand>" error!
[[ ! "$TMPDIR" && "$data_dir" ]] && export TMPDIR="$(_expand_tilde "$data_dir")/.tmp" && aba_debug "TMPDIR=$TMPDIR"
# Note that the cache is always used except for mirror-to-mirror (sync) workflows!
# Place the '.oc-mirror/.cache' into a location where there should be more space, i.e. $data_dir, if it's defined
[[ ! "$OC_MIRROR_CACHE" && "$data_dir" ]] && export OC_MIRROR_CACHE="$(_expand_tilde "$data_dir")" && aba_debug "OC_MIRROR_CACHE=$OC_MIRROR_CACHE"

# Build the base oc-mirror command. --since is only relevant for save (mirror-to-disk).
# When OC_MIRROR_SINCE is set (e.g. "2020-01-01"), archives include all content since that
# date -- use a far-back date to force a complete archive every time. When unset (default),
# oc-mirror creates differential archives (only new blobs since the last save).
# --v2 is an oc-mirror CLI flag (not related to OCP version). May become default in future releases.
base_cmd="oc-mirror --v2 --config imageset-config.yaml file://. ${OC_MIRROR_SINCE:+--since $OC_MIRROR_SINCE}"

[ "$TMPDIR" ] && mkdir -p "$TMPDIR"
[ "$OC_MIRROR_CACHE" ] && mkdir -p "$OC_MIRROR_CACHE"

if ! _run_oc_mirror_with_retry "save" "$try_tot" "$base_cmd"; then
	exit 1
fi

# Ensure all CLI downloads are complete before building transfer bundle
scripts/cli-download-all.sh --wait

# Create aba-transfer.tar: always includes ISC files so 'cp mirror/data/*.tar'
# transfers the correct imageset config to the disconnected host.
# For upgrades: also includes CLI tarballs and metadata.
# Skipped in bundle mode (aba bundle already packages everything).
if [ ! "${_ABA_BUNDLE_MODE:-}" ]; then

_transfer_tar="data/aba-transfer.tar"
_is_upgrade=""
[ "${ocp_upgrade_to:-}" ] && is_version_greater "$ocp_upgrade_to" "$ocp_version" && _is_upgrade=1

# Build the list of files to include (relative to aba root so the tar
# unpacks correctly from either mirror/ or aba/ — mirror/data/* and cli/*)
_bundle_files=()

# ISC files are always included (relative to aba root)
[ -f "data/imageset-config.yaml" ] && _bundle_files+=("mirror/data/imageset-config.yaml")
[ -f "data/imageset-config-digest.yaml" ] && _bundle_files+=("mirror/data/imageset-config-digest.yaml")

if [ "$_is_upgrade" ]; then
	_bundle_ver="$ocp_upgrade_to"
	_bundle_chan="${ocp_channel:-fast}"

	# CLI tarballs for the upgrade target version (all rhel variants).
	# Base version CLIs are already on the disconnected host from the initial install.
	for _cli_tar in ../cli/openshift-client-linux-*-"${_bundle_ver}"*.tar.gz \
	                ../cli/openshift-install-linux-"${_bundle_ver}"*.tar.gz; do
		[ -f "$_cli_tar" ] && _bundle_files+=("cli/$(basename "$_cli_tar")")
	done

	# Compute digest ISC checksum for integrity validation at load time
	_digest_isc_sha=""
	if [ -f "data/imageset-config-digest.yaml" ]; then
		_digest_isc_sha=$(sha256sum "data/imageset-config-digest.yaml" | awk '{print $1}')
	fi

	# Create metadata JSON (inside mirror/data/ so it gets packed correctly)
	cat > data/aba-transfer-metadata.json <<-METADATA
	{
	  "ocp_version": "${_bundle_ver}",
	  "ocp_channel": "${_bundle_chan}",
	  "architecture": "${ARCH:-amd64}",
	  "created": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
	  "digest_isc_sha256": "${_digest_isc_sha}"
	}
	METADATA
	_bundle_files+=("mirror/data/aba-transfer-metadata.json")
fi

aba_info "Creating transfer bundle: $_transfer_tar"

# Create the tar from aba root so paths are correct for unpack from aba root.
# CWD is mirror/ so aba root is ..
if ( cd .. && tar cf "mirror/$_transfer_tar" "${_bundle_files[@]}" ); then
	_tar_size=$(du -sh "$_transfer_tar" | awk '{print $1}')
	aba_success "Transfer bundle created: $_transfer_tar ($_tar_size)"
else
	aba_warn "Failed to create transfer bundle ($_transfer_tar)." \
		"The image archives (mirror_*.tar) are still valid." \
		"You can manually copy ISC and CLI files to the disconnected host."
fi
rm -f data/aba-transfer-metadata.json

fi  # end: transfer bundle creation

echo >&2
if [ ! "${_ABA_BUNDLE_MODE:-}" ] && [ "$_is_upgrade" ]; then
	aba_success "Upgrade images saved (${ocp_version} → ${ocp_upgrade_to})."
	echo
	aba_info "Copy all *.tar files from mirror/data/ to the disconnected host:"
	aba_info "  cp mirror/data/*.tar /transfer-media/"
	echo
	aba_info "  Files: mirror_*.tar (images), aba-transfer.tar (ISC, CLIs, metadata)"
	echo
	aba_info "On the disconnected host:"
	aba_info "  cp /transfer-media/*.tar ~/aba/mirror/data/"
	aba_info "  aba -d mirror load → aba -d <cluster> day2 → aba -d <cluster> upgrade --to ${ocp_upgrade_to}"
elif [ ! "${_ABA_BUNDLE_MODE:-}" ]; then
	aba_success "Images saved to mirror/data/."
	aba_info "Next: 'aba tar --out /path/to/portable/media/install-bundle.tar'"
fi
echo >&2

exit 0
