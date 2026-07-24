#!/bin/bash -e
# Create a install bundle which can be used to install OpenShift in an air-gapped env.

# Derive aba root from script location (this script is in scripts/)
# Use pwd -P to resolve symlinks (important when called via cluster-dir/scripts/ symlink)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
cd "$SCRIPT_DIR/.." || exit 1

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

# Wait for all CLI tarballs with retry-on-failure.
# run_once caches failures, so a bare --wait after a transient network error
# returns the stale error instantly.  Reset + backoff lets curl re-attempt.
_wait_for_cli_downloads() {
	local _max=3
	for (( _try=1; _try<=_max; _try++ )); do
		if scripts/cli-download-all.sh --wait >&2; then
			return 0
		fi
		[ $_try -lt $_max ] || { aba_info "CLI download failed after $_max attempts." >&2; return 1; }
		aba_info "CLI download failed (attempt $_try/$_max), resetting and retrying in 30s ..." >&2
		scripts/cli-download-all.sh --reset >&2
		sleep 30
	done
}

# Defense-in-depth: verify all .tar.gz files in cli/ are not truncated
_verify_cli_tarballs() {
	local f fail=0
	for f in cli/*.tar.gz; do
		[ -f "$f" ] || continue
		if ! gzip -t "$f" 2>/dev/null; then
			aba_info "ERROR: Corrupt tarball detected: $f (truncated or incomplete)" >&2
			fail=1
		fi
	done
	if [ $fail -ne 0 ]; then
		aba_info "Refusing to create bundle with corrupt CLI tarballs. Re-download with: make -C cli clean && aba cli" >&2
		return 1
	fi
	aba_debug "All CLI tarballs passed integrity check (gzip -t)"
}

aba_debug "Parsing command-line arguments: $#"
while [[ $# -gt 0 ]]; do
	case "$1" in
		--out)
			bundle_dest_file=$2
			aba_debug "Argument: --out=$bundle_dest_file"
			shift 2
			;;
		--force)
			force=1
			aba_debug "Argument: --force (will delete existing files)"
			shift
			;;
		--light)
			light_bundle=1
			aba_debug "Argument: --light (exclude image-set archives)"
			shift
			;;
		--primed)
			with_clusters="clusters=1"
			aba_debug "Argument: --primed (include pre-configured configs for air-gap transfer)"
			shift
			;;
		*)
			bundle_dest_file="$1"
			aba_debug "Argument: bundle_dest_file=$bundle_dest_file"
			shift
			;;
	esac
done

aba_debug "Options: bundle_dest_file=$bundle_dest_file force=$force light_bundle=$light_bundle with_clusters=$with_clusters"

if [ ! "$bundle_dest_file" ]; then
	bundle_dest_file=/tmp
	aba_debug "Setting install bundle output destination to /tmp (default)"
fi

aba_debug "Config: aba.conf ask=$ask ASK_OVERRIDE=$ASK_OVERRIDE"

# This will have been completed beforehand, but just in case!
aba_debug "Installing required RPMs from templates/rpms-external.txt"
install_rpms $(cat templates/rpms-external.txt) || exit 1


aba_debug "Normalizing and verifying aba.conf"
source <(normalize-aba-conf)
verify-aba-conf || aba_abort "$_ABA_CONF_ERR"
aba_debug "Configuration verified: ocp_version=$ocp_version ocp_channel=$ocp_channel"

# Kick off CLI downloads early (non-blocking) so they run in parallel with oc-mirror
aba_debug "Starting CLI downloads in background (will be waited on later)"
scripts/cli-download-all.sh

if [ "$bundle_dest_file" = "-" ]; then
	# Be sure the standard output of this command is ONLY tar output and nothing else!
	aba_debug "Bundle destination: stdout (streaming tar output)"
	aba_info "Creating install bundle (stdout) with:" >&2
else
	aba_debug "Bundle destination: file on disk"
	if [ -d "$bundle_dest_file" ]; then
		aba_debug "Destination is directory, appending default filename"
		bundle_dest_file="$bundle_dest_file/ocp-bundle"	# Correct the output location as it needs to be a file
	fi
	aba_info "Creating install bundle with:" >&2
	if [[ "$bundle_dest_file" == *.tar ]]; then
		bundle_dest_file="${bundle_dest_file%.tar}-$ocp_version.tar"  # strip .tar, append version, re-add .tar
	else
		bundle_dest_file="$bundle_dest_file-$ocp_version.tar"
	fi
	aba_debug "Final bundle destination: $bundle_dest_file"

	# Sanity write check 
	aba_debug "Testing write permissions to $bundle_dest_file"
	! echo write test > "$bundle_dest_file.tmp" && aba_abort "Cannot write to $bundle_dest_file"
	rm -f "$bundle_dest_file.tmp"
	aba_debug "Write test successful"
fi

echo >&2
normalize-aba-conf | sed "s/^export //g" | grep -E -o "^(ocp_version|pull_secret_file|ocp_channel)=[^[:space:]]*" | sed 's/^/[ABA]   /' >&2
aba_info "Bundle output file = $bundle_dest_file" >&2
echo >&2

# User requires to clean out any existing files under mirror/data
if [ "$force" ]; then
{
	aba_debug "Force flag set - cleaning existing ABA-owned files"
	if [ -d mirror/data ]; then
		aba_debug "Cleaning ABA-owned files in mirror/data (preserving oc-mirror working-dir/)"
		aba_warn "Deleting ABA-owned files under aba/mirror/data/ (--force set)" >&2
		rm -f mirror/data/imageset*.yaml mirror/data/mirror_*.tar mirror/data/aba-transfer*.* mirror/data/.created mirror/data/.isc-pinned
		aba_debug "ABA-owned files removed (working-dir/ preserved)"
	else
		aba_debug "mirror/data directory doesn't exist"
	fi

	if [ -f "$bundle_dest_file" ]; then
		aba_debug "Deleting existing bundle file: $bundle_dest_file"
		aba_warn "Deleting existing bundle file: $bundle_dest_file (--force set)" >&2
		rm -f "$bundle_dest_file"
		aba_debug "Bundle file deleted"
	else
		aba_debug "No existing bundle file to delete"
	fi

	# Ensure files are refreshed 
	aba_debug "Cleaning CLI directory: $PWD/cli"
	aba_info "Deleting unwanted CLI install files under $PWD/cli ..." >&2
	###ls -1 cli/*tar.gz 2>/dev/null | grep -v -e "-$ocp_version.tar.gz" -e "oc-mirror.*.tar.gz" -e "govc_Linux" | xargs rm -f || true  # ignore any errors
	make -sC cli clean >&2
	aba_debug "CLI directory cleaned"
	##run_once -r -i "cli:install:oc-mirror"  # If we clean up files, we must *reset* the task tracker/runner

	#run_once -r -i "download_all_cli"  	   # If we clean up files, we must *reset* the task tracker/runner
	###scripts/cli-download-all.sh --reset
} >&2
else
	aba_debug "Force flag not set - checking for existing files"
fi

# Check if the repo is alreay in use, e.g. we don't want mirror.conf in the bundle
# "-f, --force" means that "aba bundle" can be run again & again and the image-set config file will be re-created every time
# If these files are generated by aba, then we just ignore them
# Detect if user mods have been made to imageset-config.yaml file
# If --force set these files will have been deleted above
aba_debug "Checking if repository is already in use"
if [ -d mirror/data ]; then
	aba_debug "mirror/data directory exists, checking for existing files"
	if [ mirror/data/imageset-config.yaml -nt mirror/data/.created ]; then
		aba_debug "imageset-config.yaml has been modified since creation"
		# Detect if any image-set archive files exist
		ls mirror/data/mirror_*\.tar >/dev/null 2>&1 && image_set_files_exist=1
		aba_debug "Image-set archive files exist: ${image_set_files_exist:-no}"

		if [ -s mirror/data/imageset-config.yaml ] || [ -f mirror/mirror.conf ] || [ "$image_set_files_exist" ]; then
			aba_debug "Repository appears to be in use - prompting user"
			aba_warn "This repo is already in use!  Modified files exist under: mirror/data" >&2
			echo -n "         " >&2;  ls mirror/data >&2
			[ "$image_set_files_exist" ] && \
			aba_warn "Image set archive file(s) also exist." >&2
			aba_warn "Back up any required files and try again with '--force' to delete all existing files under mirror/data." \
				"Or, use a fresh Aba repo and try again!" >&2
			ask "         Files will be overwritten. Continue anyway" >&2 || exit 1
			aba_debug "User confirmed to continue with existing files"
		else
			aba_debug "No conflicting files found"
		fi
	else
		aba_debug "imageset-config.yaml not modified or doesn't exist"
	fi
else
	aba_debug "mirror/data directory doesn't exist - fresh installation"
fi

# Suppress end-of-save hints in reg-save.sh (bundle flow handles its own messaging)
export _ABA_BUNDLE_MODE=1

# This is a special case where we want to only send the tar repo contents to stdout 
# so we can do something like: aba bundle ... --out - | ssh host tar xvf - 
if [ "$bundle_dest_file" = "-" ]; then
	aba_debug "Stdout mode: streaming tar bundle to stdout"
	aba_info "Downloading binary data." >&2  # Must use stderr channel here

	aba_debug "Calling: make -s -C mirror save retry=2"
	make -s -C mirror save retry=2 >&2 	|| exit 1
	aba_debug "Mirror save completed successfully"

	aba_info "Ensuring all CLI installation files are downloaded..." >&2
	aba_debug "Waiting for all CLI tarball downloads to complete"
	_wait_for_cli_downloads || exit 1
	aba_debug "All CLI tarballs downloaded"

	aba_info "Writing install bundle (tar format) to stdout ..." >&2
	aba_debug "Calling: make -s tar out=- $with_clusters"
	make -s tar out=- $with_clusters   # Be sure the output of this command is ONLY tar output!

	aba_debug "Stdout bundle creation complete, exiting"
	exit
fi

aba_debug "Checking if bundle file already exists: $bundle_dest_file"
if [ -s "$bundle_dest_file" ]; then
	aba_debug "Bundle file exists, prompting user for overwrite confirmation"
	aba_warn "File $bundle_dest_file already exists!" 
	ask "The file will be overwritten. Continue anyway" || exit 1
	aba_debug "User confirmed to overwrite existing bundle"
else
	aba_debug "Bundle file does not exist, proceeding"
fi


# Light bundle flag give?
if [ "$light_bundle" ]; then
	# User wants to create a *light* bundle...
	aba_debug "Creating LIGHT bundle (excluding image-set archives)"

	aba_info "A *light* install bundle will be created (image-set archives excluded)."

	# Create light bundle with "aba tarrepo..."
	aba_info "Pulling images ..."
	aba_debug "Calling: make -s -C mirror save retry=2"
	make -s -C mirror save retry=2				# Pull required release (and possibly operator) images.  Retry on failure.
	aba_debug "Mirror save completed"
	
	aba_info "Ensuring all CLI installation files are downloaded..."
	aba_debug "Waiting for all CLI tarball downloads to complete"
	_wait_for_cli_downloads || exit 1
	_verify_cli_tarballs || exit 1
	aba_debug "All CLI tarballs downloaded and verified"
	
	aba_info "Creating *light* install bundle archive ..."
	rm -f "$bundle_dest_file"
	aba_debug "Calling: make tarrepo out=$bundle_dest_file $with_clusters"
	make -s tarrepo out="$bundle_dest_file" $with_clusters			# Create install bundle containing the repo ONLY and excluding large imageset file(s).
	aba_debug "Light bundle created successfully: $bundle_dest_file"
else
	# Create a full install bundle containing the repo AND the image-set archive file(s) ...
	aba_debug "Creating FULL bundle (including image-set archives)"
	
	if files_on_same_device mirror "$bundle_dest_file"; then
		aba_debug "Mirror and bundle destination are on same filesystem - disk space warning"
		_mount_point=$(df --output=target "$(dirname "$bundle_dest_file")" 2>/dev/null | tail -1)
		# FIXME: Do rough calculation of available vs required disk space ... and check ...
		aba_warn \
			"Make sure there is enough free disk space under: $PWD" \
			"The image-set archive file(s) created by oc-mirror will first be written to" \
			"aba/mirror/data/mirror_000001.tar, and then a full copy of the Aba repository will be written" \
			"to the bundle file you specified: $bundle_dest_file" \
			"Because both files *reside on the same filesystem* (${_mount_point:-unknown}), you may temporarily" \
			"need roughly double the required space (or more if you consider the oc-mirror cache). " \
			">> IMPORTANT: <<" \
			"If disk space is limited, consider using the '--light' option." \
			"It excludes the large image-set archive file(s) from the final install bundle." \
			"This is also useful in restricted environments where large archives cannot be stored or" \
			"moved via portable media (for example, Cloud instances or locked-down laptops)."

		ask "Continue anyway" || exit 1
		aba_debug "User confirmed to continue with full bundle on same filesystem"
	else
		aba_debug "Mirror and bundle destination are on different filesystems - no disk space concern"
	fi

	# Create full bundle ... with "aba tar..."
	aba_info "Pulling images to disk ..."
	aba_debug "Calling: make -s -C mirror save retry=2"
	make -s -C mirror save retry=2		    		# Pull required release (and possibly operator) images.  Retry on failure.
	aba_debug "Mirror save completed"
	
	aba_info "Ensuring all CLI installation files are downloaded..."
	aba_debug "Waiting for all CLI tarball downloads to complete"
	_wait_for_cli_downloads || exit 1
	_verify_cli_tarballs || exit 1
	aba_debug "All CLI tarballs downloaded and verified"
	
	aba_info "Creating install bundle archive ..."
	rm -f "$bundle_dest_file"
	aba_debug "Calling: make tar out=$bundle_dest_file $with_clusters"
	make -s tar out="$bundle_dest_file" $with_clusters	   		# Create all-in-one archive, including all files.
	aba_debug "Full bundle created successfully: $bundle_dest_file"
fi

echo >&2
aba_info "For subsequent updates: aba save, then transfer mirror/data/*.tar to the disconnected host. See README.md 'Air-Gapped Transfer'." >&2

aba_debug "Bundle creation completed, exiting successfully"
exit 0
