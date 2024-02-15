#!/bin/bash -e
# Incremental backups script.  Used to only backup (and copy) the changes since the last backup.

[ "$1" ] && dir="$1" || dir=/tmp

now=$(date "+%Y-%m-%d-%H-%M-%S")

if [ "$dir" != "-" ]; then
	dest=$dir/image-backup-$now.tgz

	echo "Writing tar file"
	echo
	echo "After the tar file has been written, copy the tar file to your *internal bastion* and"
	echo "extract it under your home directory with the command:"
	echo "cd; tar xzvf /path/to/image-backup-<timestamp>.tgz"
	echo
	echo "Load (and install, if needeed) the registry"
	echo "make load"
	echo
	echo "Create the iso and install a cluster"
	echo "make cluster name=mycluster"
	echo "cd mycluster; make help"
	echo
	echo "Writing tar file to $dest (use 'make tar out=/path/to/thumbdrive' to write to your portable storage device) ..."
else
	dest="-"
fi

if [ ! -f .backup.time.previous ]; then
	rm -f .backup.time.*
	# Do first full backup, exit if backup fails
	tar czf $dest $(find s*/oc-mirror-workspace/ -type f) || exit 
else
	# Do inc. backup since the last backup, exit if backup fails
	file_list=$(find s*/oc-mirror-workspace/ -type f -newer .backup.time.previous) 
	[ ! "$file_list" ] && echo "No files newer than '.backup.time.previous' to backup" >&2 && exit 
	tar czf $dest $file_list || exit
fi
time_stamp_file=.backup.time.$now
touch $time_stamp_file && ln -fs $time_stamp_file .backup.time.previous

