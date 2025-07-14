#!/bin/bash 
# Create a install bundle which can be used to install OCP in an air-gapped env.

source scripts/include_all.sh

[ "$1" ] && bundle_dest_path=$1 && shift
[ "$1" ] && force=true && shift
[ "$1" ] && set -x

# This will have been completed behand, but just in case!
install_rpms $(cat templates/rpms-external.txt) || exit 1

source <(normalize-aba-conf)

verify-aba-conf || exit 1

[ ! "$bundle_dest_path" ] && echo_red "Error: missing install bundle filename! Example: /mnt/usb-media/my-bundle" >&2 && exit 1

if [ "$bundle_dest_path" = "-" ]; then
	echo_cyan "An install bundle will be generated and written to standard output using the following parameters:" >&2
else
	[ -d $bundle_dest_path ] && bundle_dest_path=$bundle_dest_path/ocp-bundle	# Correct the output location as it needs to be a file
	echo_cyan "An install bundle file will be generated and saved to disk using the following parameters:" >&2
	bundle_dest_path="$bundle_dest_path-$ocp_version"
fi

echo >&2
normalize-aba-conf | sed "s/^export //g" | grep -E -o "^(ocp_version|pull_secret_file|ocp_channel)=[^[:space:]]*" >&2

echo Bundle output file = $bundle_dest_path >&2
echo >&2

# Check if the repo is alreay in use, e.g. we don't want mirror.conf in the bundle
# "-f, --force" means that "aba bundle" can be run again & again and the image set config file will be re-created every time
#force=1 # $force now comes from "--force" option
if [ -d mirror/save ]; then
	if [ ! "$force" ]; then
		# Detect if any image set archive files exist
		ls mirror/save/mirror_*\.tar >/dev/null 2>&1 && image_set_files_exist=1

		if [ -s mirror/save/imageset-config-save.yaml -o -f mirror/mirror.conf -o "$image_set_files_exist" ]; then
			echo_red "Warning: This repo is already in use!  Files exist under: mirror/save" >&2
			echo -n "         " >&2
			ls mirror/save >&2
			[ "$image_set_files_exist" ] && \
			echo_red "         Image set archive files also exist." >&2
			echo_red "         Back up any required files and try again with the '--force' flag to delete all existing files under mirror/save" >&2
			echo_red "         Or, use a fresh Aba repo and try again!" >&2 
			echo >&2

			ask "         Continue anyway" >&2 || exit 1
		fi
	else
		if [ "$(ls mirror/save)" ]; then
			echo_red "Deleteing all files under aba/mirror/save! (--force set)" >&2
			echo >&2
			rm -rf mirror/save/*
		fi
	fi
fi

# This is a special case where we want to only send the tar repo contents to stdout 
# so we can do something like: aba bundle ... --out - | ssh host tar xvf - 
if [ "$bundle_dest_path" = "-" ]; then
	#echo "Downloading binary data.  See logfile '.bundle.log' for details." >&2
	echo "Downloading binary data." >&2

	#make -s download save retry=7 2>&1 | cat -v >>.bundle.log
	make -s download save retry=7 >&2 || exit 1  # Add this here since if there is issue (e.g. op. index failed to d/l) should stop.

	echo_cyan "Writing 'all-in-one' install bundle (tar format) to stdout ..." >&2
	make -s tar out=-   # Be sure the output of this command is ONLY tar output!

	exit
fi

if files_on_same_device mirror $bundle_dest_path; then
	echo_cyan "Creating 'split' install bundle (because the bundle is on the same file-system as the image set archive file) ..."
	echo_magenta "TO CREATE A FULL BUNDLE INSTEAD, WRITE THE ARCHIVE DIRECTLY TO EXTERNAL MEDIA OR A SEPARATE DRIVE."
	echo
	sleep 2
	#make download save tarrepo out="$bundle_dest_path" retry=7 || exit 1	# Try save 8 times, then create archive of the repo ONLY, excluding large imageset files.
	aba download save tarrepo --out "$bundle_dest_path" --retry 7 || exit 1	# Try save 8 times, then create archive of the repo ONLY, excluding large imageset files.
else
	echo_cyan "Creating 'all-in-one' install bundle (assuming destination file is on portable media or a different file-system) ..."
	#make download save tar out="$bundle_dest_path" retry=7 || exit 1    	# Try save 8 times, then create all-in-one archive, including all files. 
	aba download save tar     --out "$bundle_dest_path" --retry 7 || exit 1    	# Try save 8 times, then create all-in-one archive, including all files. 
fi

exit 0
