#!/bin/bash -e
# Incremental backups script.  Used to only backup (and copy) the changes since the last backup.

[ "$1" ] && dir="$1" || dir=/tmp

now=$(date "+%Y-%m-%d-%H-%M-%S")

cd ..  # Assume 'kame inc' runs from aba's top level dir
mkdir -p ~/.aba   # Store all time stamp files in here

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

[ ! -f ~/.aba/previous.backup ] && touch -t 7001010000 ~/.aba/previous.backup

#find ~/.aba/backup* -type f ! -newer ~/.aba/previous.backup | xargs echo rm 

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
-type f \
	! -path "aba/.git*" -a \
	! -path "aba/cli/*" -a \
	! -path "aba/mirror/mirror-registry" -a \
	! -path "aba/mirror/.initialized" \
	! -path "aba/mirror/.rpms" \
	! -path "aba/mirror/.installed" \
	! -path "aba/mirror/.loaded" \
	! -path "aba/mirror/execution-environment.tar" \
	! -path "aba/mirror/image-archive.tar" \
	! -path "aba/mirror/quay.tar" \
	! -path "aba/mirror/pause.tar" \
	! -path "aba/mirror/postgres.tar" \
	! -path "aba/mirror/redis.tar" \
	! -path "aba/*/iso-agent-based*" \
-newer ~/.aba/previous.backup \
)

[ ! "$file_list" ] && echo "No new files to backup" >&2 && exit 1
echo Generating tar archive to $dest >&2
tar czf $dest $file_list || exit 


time_stamp_file=~/.aba/backup.time.$now
touch $time_stamp_file && ln -fs $time_stamp_file ~/.aba/previous.backup

