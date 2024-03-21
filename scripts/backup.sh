#!/bin/bash -e
# Tar backup script for full and incremental backups.  Used to only backup (and copy) the changes since the last backup.
# Usage: backup.sh [--inc] [--repo] [file]
#                   --inc	incremental backup based on the ~/.aba.previous.backup flag file's timestamp
#                   --repo	exclude all */mirror_seq*tar files from the archive.  Copy them separately, if needed.

dest=/tmp/aba-backup.tar	# Default file to write to
inc= 				# Full backup by default
repo_only=			# Also include the save/mirror_seq*.tar files (for some use-cases it's more efficient to keep them seperate) 

while echo "$1" | grep -q ^--[a-z]
do
	[ "$1" = "--repo" ] && repo_only=1 && shift		# Set to NOT include any mirror_seq*.tar files
	[ "$1" = "--inc" ] && inc=1 && shift    		# Set optional backup type to "incremental".  Full is default. 
done

[ "$1" ] && dest="$1"

# Append .tar if it's missing from filename (ignore stdout) 
if [ "$dest" != "-" ]; then
	echo "$dest" | grep -q \.tar$ || dest="$dest.tar"

	# If the destination file already exists...
	[ -s $dest ] && echo "Warning: File $dest already exists" && exit 1
fi


# Assume this script is run via 'cd aba; make inc', i.e. runs from aba's top level dir
cd ..  

# If this is the first run OR is doing a full backup ... Set up for full backup 
[ ! -f ~/.aba.previous.backup -o ! "$inc" ] && touch -t 7001010000 ~/.aba.previous.backup && echo "Resetting timestamp file: ~/.aba.previous.backup" >&2

file_list=$(find		\
	bin			\
	aba/aba			\
	aba/aba.conf		\
	aba/Makefile		\
	aba/mirror		\
	aba/others		\
	aba/README.md		\
	aba/README-OTHER.md	\
	aba/scripts		\
	aba/templates		\
	aba/Troubleshooting.md	\
	aba/vmware.conf		\
	aba/rpms		\
	aba/test		\
-type f \
	! -path "aba/.git*" -a 				\
	! -path "aba/cli/*" -a 				\
	! -path "aba/mirror/mirror-registry" -a 	\
	! -path "aba/mirror/.initialized" 		\
	! -path "aba/mirror/.rpms" 			\
	! -path "aba/mirror/.installed" 		\
	! -path "aba/mirror/.loaded" 			\
	! -path "aba/mirror/execution-environment.tar" 	\
	! -path "aba/mirror/image-archive.tar" 		\
	! -path "aba/mirror/quay.tar" 			\
	! -path "aba/mirror/pause.tar" 			\
	! -path "aba/mirror/postgres.tar" 		\
	! -path "aba/mirror/redis.tar" 			\
	! -path "aba/*/iso-agent-based*" 		\
	! -path "aba/mirror/sync/oc-mirror-workspace*" 	\
	! -path "aba/mirror/save/oc-mirror-workspace*" 	\
							\
	-newer ~/.aba.previous.backup 			\
)

# If we only want the repo, without the mirror tar files, then we need to filter these out of the list
[ "$repo_only" ] && file_list=$(echo "$file_list" | grep -v "^aba/mirror/s.*/mirror_seq.*.tar$") || true  # 'true' needed!

# Clean up file_list
file_list=$(echo "$file_list" | sed "s/^ *$//g")  # Just in case file_list="  "

[ ! "$file_list" ] && echo "No new files to backup!" >&2 && exit 0

[ "$repo_only" ] && echo "Warning: Not archiving any mirror/*/mirror_seq*.tar files! You will need to copy them into mirror/save/." >&2

if [ "$dest" != "-" ]; then
	### now=$(date "+%Y-%m-%d-%H-%M-%S")

	echo "Writing tar file to $dest"
	echo
	echo "After the tar file has been written, copy the tar file to your *internal bastion* and"
	echo "extract it under your home directory with the command:"
	echo "cd; rm -rf aba; tar xvf $dest"
	echo
	echo "Install (or connect) and load the registry:"
	echo "make install"
	echo "make load"
	echo
	echo "Then, create the iso file and install a cluster:"
	echo "make cluster name=mycluster"
	echo "cd mycluster; make or make help"
	echo
	echo "Writing tar file to $dest (use 'make tar out=/path/to/thumbdrive' to write to your portable storage device) ..."
	echo "Run 'make help' for more options."
fi

if [ "$inc" ]; then
	echo "Writing 'incremental' tar archive to $dest" >&2
else
	echo "Writing 'full' tar archive to $dest" >&2
fi

echo "Running: `pwd` tar cf $dest <files>" >&2
### echo file_list=$file_list >&2
tar cf $dest $file_list || exit 

# Upon success, make a note of the time
echo "Touching file ~/.aba.previous.backup" >&2
touch ~/.aba.previous.backup

