#!/bin/bash -e
# Tar backup script for full OR incremental backups.  Used to only backup (and copy) the changes since the last backup.
# Usage: backup.sh [--inc] [--repo] [file]
#                   --inc	incremental backup based on the ~/.aba.previous.backup flag file's timestamp
#                   --repo	exclude all */mirror_seq*tar files from the archive.  Copy them separately, if needed.

source scripts/include_all.sh

dest=/tmp/aba-backup.tar	# Default file to write to
inc= 				# Full backup by default
repo_only=			# Also include the save/mirror_seq*.tar files (for some use-cases it's more efficient to keep them seperate) 

while echo "$1" | grep -q ^--[a-z]
do
	[ "$1" = "--repo" ] && repo_only=1 && shift		# Set to NOT include any mirror_seq*.tar files, which can be copied separately. 
	[ "$1" = "--inc" ] && inc=1 && shift    		# Set optional backup type to "incremental".  Full is default. 
done

[ "$1" ] && dest="$1"

# Append .tar if it's missing from filename (ignore stdout) 
if [ "$dest" != "-" ]; then
	echo "$dest" | grep -q \.tar$ || dest="$dest.tar"

	# If the destination file already exists...
	[ -s $dest ] && echo "Warning: File $dest already exists" >&2 && exit 1
fi

# Assume this script is run via 'make ...' from aba's top level dir
cd ..  

# If this is the first run OR is doing a full backup ... Set up for full backup 
#[ ! -f ~/.aba.previous.backup -o ! "$inc" ] && touch -t 7001010000 ~/.aba.previous.backup && echo "Resetting timestamp file: ~/.aba.previous.backup" >&2
[ ! -f ~/.aba.previous.backup -o ! "$inc" ] && touch -t 7001010000 ~/.aba.previous.backup ### && echo "Resetting timestamp file: ~/.aba.previous.backup" >&2

	###bin			\
	# Remove bin in favour of cli/
	#aba/vmware.conf		\
	# vmware only on "internal" bastion


# Add the flag file so when aba is run again it knows it's a bundle!
touch aba/.bundle  # Flag this archive as a bundle
rm -f aba/.aba.conf.seen   # Ensure user has chance to edit this conf file again on the internal network

# All 'find expr' below are by default "and"
file_list=$(find		\
	aba/aba			\
	aba/aba-old		\
	aba/.bundle		\
	aba/aba.conf		\
	aba/cli			\
	aba/rpms		\
	aba/mirror		\
	aba/others		\
	aba/scripts		\
	aba/templates		\
	aba/Makefile		\
	aba/README.md		\
	aba/README-OTHER.md	\
	aba/Troubleshooting.md	\
	aba/test		\
	! -path "aba/.git*"  					\
	! -path "aba/cli/.init"  				\
	! -path "aba/cli/.??*"	  				\
	! -path "aba/mirror/.initialized"  			\
	! -path "aba/mirror/.rpms"  				\
	! -path "aba/mirror/.installed"  			\
	! -path "aba/mirror/.loaded" 				\
	! -path "aba/mirror/mirror-registry"  			\
	! -path "aba/mirror/execution-environment.tar"  	\
	! -path "aba/mirror/image-archive.tar"  		\
	! -path "aba/mirror/quay.tar"  				\
	! -path "aba/mirror/pause.tar"  			\
	! -path "aba/mirror/postgres.tar"  			\
	! -path "aba/mirror/redis.tar"  			\
	! -path "aba/mirror/regcreds/*"	  			\
	! -path "aba/*/iso-agent-based*"  			\
	! -path "aba/mirror/sync/oc-mirror-workspace*"  	\
	! -path "aba/mirror/save/oc-mirror-workspace*"		\
								\
	\( -type f -o -type l \)				\
								\
	-newer ~/.aba.previous.backup 				\
)

#
# Note, don't copy over any of the ".initialized", ".installed", ".rpms" flag files etc, since these components are needed on the internal bastion
# Don't copy those very large 'tar' files since we have them compressed already.
# Don't need to copy over the oc-mirror-workspace dirs.  The needed yaml files for 'make day2' are created at 'make load'.

# If we only want the repo, without the mirror tar files, then we need to filter these out of the list
[ "$repo_only" ] && file_list=$(echo "$file_list" | grep -v "^aba/mirror/s.*/mirror_seq.*.tar$") || true  # 'true' needed!

# Clean up file_list
file_list=$(echo "$file_list" | sed "s/^ *$//g")  # Just in case file_list="  " white space

[ ! "$file_list" ] && echo "No new files to backup!" >&2 && exit 0

[ "$repo_only" ] && echo "Warning: Not archiving any mirror/*/mirror_seq*.tar files! You will need to copy them into mirror/save/ yourself." >&2

if [ "$dest" != "-" ]; then
	### now=$(date "+%Y-%m-%d-%H-%M-%S")

	echo
	echo_white "Writing tar file (bundle archive) to $dest"
	echo
	echo_white "After the bundle has been written, copy it to your *internal bastion*"
	echo_white "Remember to copy over the large tar file(s) too, e.g. with the command:"
	echo_white " cp mirror/save/mirror_seq*.tar <path to your portable media/usb stick/thumbdrive>"
	echo_white "Transfer the bundle and the tar file(s) to your internal bastion."
	echo_white "Extract the bundle tar file anywhere under your home directory & continue, e.g. with the commands:"
	echo_white "  tar xvf $(basename $dest)"
	echo_white "  mv mirror_seq*.tar aba/mirror/save"
	echo_white "  cd aba"
	echo_white "  ./aba"
	echo
	echo_white "Run 'make help' for all options."
fi

if [ "$inc" ]; then
	echo_blue "Writing 'incremental' tar archive of repo to $dest" >&2
else
	echo_blue "Writing 'full' tar archive of repo to $dest" >&2
fi

out_file_list=$(echo $file_list | cut -c-90)
echo >&2
echo_blue "Running: 'tar cf $dest $out_file_list...' from inside $PWD" >&2
echo >&2
### echo file_list=$file_list >&2
if ! tar cf $dest $file_list; then
	rm -f aba/.bundle
	exit
fi

rm -f aba/.bundle

#if [ "$inc" ]; then
# Changing this.  if "not repo backup only" (so, if 'inc' or 'tar'), then always create timestamp file so that future inc backups will not backup everything.
if [ ! "$repo_only" ]; then
	# Upon success, make a note of the time
	echo_blue "Touching file ~/.aba.previous.backup" >&2
	touch ~/.aba.previous.backup
fi

