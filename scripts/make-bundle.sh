#!/bin/bash 
# Create a bundle archive which can be used to install OCP in an air-gapped env.

source scripts/include_all.sh

[ "$1" ] && bundle_dest_path=$1 && shift
[ "$1" ] && force=true && shift
[ "$1" ] && set -x

install_rpms make | cat -v >.bundle.log|| exit 1

source <(normalize-aba-conf)

[ ! "$bundle_dest_path" ] && echo_red "Error: missing bundle archive filename! Example: /mnt/usb-media/my-bundle" >&2 && exit 1

if [ "$bundle_dest_path" = "-" ]; then
	echo_cyan "A bundle archive will be output using the following values:" >&2
else
	echo_cyan "A bundle archive file will be created using the following values:" >&2
	bundle_dest_path="$bundle_dest_path-$ocp_version"
fi

echo >&2
normalize-aba-conf | sed "s/^export //g" | grep -E -o "^(ocp_version|pull_secret_file|ocp_channel)=[^[:space:]]*" >&2

echo Bundle output file = $bundle_dest_path >&2
echo >&2

# Check if the repo is alreay in use, e.g. we don't want mirror.conf in the bundle
# "force" would mean that "make bundle" can be run again and again.
force=1 # FIXME
if [ ! "$force" ]; then
	if [ -s mirror/save/imageset-config-save.yaml -o -f mirror/mirror.conf ]; then
		echo_red "This repo is already in use!  Use a fresh Aba repo or run 'make distclean' and try again!" >&2

		exit 1
	fi
fi

#if [ -s mirror/save/imageset-config-save.yaml ]; then
#	if ask "Create bundle file (mirror/save/imageset file will be backed up)"; then
#		mv -v mirror/save/imageset-config-save.yaml mirror/save/imageset-config-save.yaml.backup.$(date +%Y%m%d-%H%M) >&2
#	else
#		exit 1
#	fi
#fi

# This is a special case where we want to only output the tar repo contents to stdout 
# so we can do something like: ./aba bundle ... --bundle-file - | ssh host tar xvf - 
if [ "$bundle_dest_path" = "-" ]; then
	echo "Downloading binary data.  See logfile '.bundle.log' for details." >&2
	make -s download save retry=7 | cat -v >>.bundle.log 2>&1
	make -s tar out=-

	exit
fi

if files_on_same_device mirror $bundle_dest_path; then
	#make bundle out="$bundle_dest_path" retry=7  # Try 8 times!
	echo_cyan "Creating minor bundle archive (because files are on same file system) ..."
	make download save tarrepo out="$bundle_dest_path" retry=7	# Try save 8 times, then create archive of the repo ONLY, excluding large imageset files.
else
	echo_cyan "Creating full bundle archive (assuming destination file is on portable media) ..."
	make download save tar out="$bundle_dest_path" retry=7    	# Try save 8 times, then create full archive, including all files. 
fi

exit 0
