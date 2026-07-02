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
if [ "${ocp_version_target:-}" ] && [ "$ocp_version_target" != "$ocp_version" ]; then
	aba_info "Verifying release image availability for upgrade target v${ocp_version_target} ..."
	if ! verify_release_version_exists "$ocp_version_target"; then
		aba_abort \
			"Upgrade target version $ocp_version_target not found in '${ocp_channel}' channel (arch: ${ARCH:-amd64})." \
			"This version may not have been released yet, or the channel may be wrong." \
			"Use 'aba ocp-versions' to list available versions."
	fi
	# Fail fast: verify upgrade path exists before starting downloads
	_path_diag=""
	if ! _path_diag=$(verify_upgrade_path_exists "$ocp_version" "$ocp_version_target" "$ocp_channel" 2>&1); then
		_tgt_ch="${_path_diag#*|}" && _tgt_ch="${_tgt_ch%%|*}"   # middle field (target channel)
		_lowest="${_path_diag##*|}"                              # last field (lowest entry point)
		aba_abort \
			"Cannot upgrade directly from $ocp_version to $ocp_version_target." \
			"Version $ocp_version is not in channel ${_tgt_ch} (lowest entry: ${_lowest:-unknown})." \
			"You need to upgrade to at least ${_lowest:-a version in ${_tgt_ch}} first." \
			"" \
			"Verify upgrade paths at: https://access.redhat.com/labs/ocpupgradegraph/update_path/"
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

# Also download CLIs for the upgrade target version (needed on disconnected host)
if [ "${ocp_version_target:-}" ] && [ "$ocp_version_target" != "$ocp_version" ]; then
	aba_info "Downloading CLI binaries for target version $ocp_version_target ..."
	scripts/cli-download-all.sh --target-version "$ocp_version_target"
fi

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
	aba_warning "Very low disk space under $PWD/data (only $avail MB free)" \
		"A first-time save requires at least 20GB for the base platform alone" \
		"Operators require additional 40-400GB of space" \
		"Incremental saves may succeed with less space"
	echo >&2
elif [ $avail -lt 51250 ]; then
	aba_warning "Less than 50GB of space available under $PWD/data (only $avail MB)" \
		"Operator images require between ~40 to ~400GB of disk space!"
	echo >&2
fi

aba_info "Using oc-mirror version $(oc_mirror_version)"
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

# Ensure all CLI downloads are complete before building upgrade bundle
scripts/cli-download-all.sh --wait

# Create aba-upgrade.tar containing ISC, digest ISC, CLI tarballs, and metadata.
# This is always created — for initial installs, the full install bundle is preferred,
# but having the upgrade bundle alongside doesn't hurt.
_bundle_ver="${ocp_version_target:-$ocp_version}"
_bundle_chan="${ocp_channel:-fast}"
_upgrade_tar="data/aba-upgrade.tar"

aba_info "Creating upgrade bundle: $_upgrade_tar"

# Build the list of files to include (relative to aba root so the tar
# unpacks correctly from either mirror/ or aba/ — mirror/data/* and cli/*)
_bundle_files=()

# ISC files (relative to aba root)
[ -f "data/imageset-config.yaml" ] && _bundle_files+=("mirror/data/imageset-config.yaml")
[ -f "data/imageset-config-digest.yaml" ] && _bundle_files+=("mirror/data/imageset-config-digest.yaml")

# CLI tarballs for the target version (all rhel variants)
for _cli_tar in ../cli/openshift-client-linux-*-"${_bundle_ver}"*.tar.gz \
                ../cli/openshift-install-linux-"${_bundle_ver}"*.tar.gz; do
	[ -f "$_cli_tar" ] && _bundle_files+=("cli/$(basename "$_cli_tar")")
done

# Also include CLIs for the base version if doing a cross-minor upgrade
if [ "$ocp_version_target" ] && [ "$ocp_version_target" != "$ocp_version" ]; then
	for _cli_tar in ../cli/openshift-client-linux-*-"${ocp_version}"*.tar.gz \
	                ../cli/openshift-install-linux-"${ocp_version}"*.tar.gz; do
		[ -f "$_cli_tar" ] && _bundle_files+=("cli/$(basename "$_cli_tar")")
	done
fi

# Compute digest ISC checksum for integrity validation at load time
_digest_isc_sha=""
if [ -f "data/imageset-config-digest.yaml" ]; then
	_digest_isc_sha=$(sha256sum "data/imageset-config-digest.yaml" | awk '{print $1}')
fi

# Create metadata JSON (inside mirror/data/ so it gets packed correctly)
cat > data/aba-upgrade-metadata.json <<-METADATA
{
  "ocp_version": "${_bundle_ver}",
  "ocp_channel": "${_bundle_chan}",
  "architecture": "${ARCH:-amd64}",
  "created": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "digest_isc_sha256": "${_digest_isc_sha}"
}
METADATA
_bundle_files+=("mirror/data/aba-upgrade-metadata.json")

# Create the tar from aba root so paths are correct for unpack from aba root.
# CWD is mirror/ so aba root is ..
if ( cd .. && tar cf "mirror/$_upgrade_tar" "${_bundle_files[@]}" ); then
	_tar_size=$(du -sh "$_upgrade_tar" | awk '{print $1}')
	aba_info_ok "Upgrade bundle created: $_upgrade_tar ($_tar_size)"
else
	aba_warning "Failed to create upgrade bundle ($_upgrade_tar)." \
		"The image archives (mirror_*.tar) are still valid." \
		"You can manually copy ISC and CLI files to the disconnected host."
fi
rm -f data/aba-upgrade-metadata.json

echo
if [ "$ocp_version_target" ] && [ "$ocp_version_target" != "$ocp_version" ]; then
	aba_info_ok "Upgrade images saved (${ocp_version} → ${ocp_version_target})."
	aba_info_ok ""
	aba_info_ok "Copy all *.tar files from mirror/data/ to the disconnected host:"
	aba_info_ok "  cp mirror/data/*.tar /transfer-media/"
	aba_info_ok ""
	aba_info_ok "  Files: mirror_*.tar (images), aba-upgrade.tar (ISC, CLIs, metadata)"
	aba_info_ok ""
	aba_info_ok "On the disconnected host:"
	aba_info_ok "  cp /transfer-media/*.tar ~/aba/mirror/data/"
	aba_info_ok "  aba -d mirror load → aba -d <cluster> day2 → aba -d <cluster> upgrade --to ${ocp_version_target}"
else
	aba_info_ok "Use 'aba tar --out /path/to/large/portable/media/install-bundle.tar' to create an install bundle which can be transferred to your disconnected environment."
	aba_info_ok "In your disconnected environment, unpack the install bundle and run 'cd aba; ./install; aba' for further instructions."
fi
echo

exit 0
