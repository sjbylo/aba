#!/bin/bash -e
# Incremental backups script.  Used to only backup (and copy) the changes since the last backup.

[ "$1" ] && dir="$1" || dir=/tmp

now=$(date "+%Y-%m-%d-%H-%M-%S")

cd ..  # Assume this script is run via 'make inc', i.e. runs from aba's top level dir

[ ! -f ~/.aba.previous.backup ] && touch -t 7001010000 ~/.aba.previous.backup   # Set up for initial full backup 

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
	\
	-newer ~/.aba.previous.backup 			\
)

[ ! "$file_list" ] && echo "No new files to backup" >&2 && exit 0

if [ "$dir" != "-" ]; then
	dest=$dir/image-backup-$now.tgz

	echo "Writing tar file to $dest"
	echo
	echo "After the tar file has been written, copy the tar file to your *internal bastion* and"
	echo "extract it under your home directory with the command:"
	echo "cd; tar xzvf /path/to/image-backup-$now.tgz"
	echo
	echo "Load (and install, if needeed) the registry"
	echo "make load"
	echo
	echo "Then, create the iso file and install a cluster:"
	echo "make cluster name=mycluster"
	echo "cd mycluster; make or make help"
	echo
	echo "Writing tar file to $dest (note, run 'make help' for more options)"
else
	dest="-"
fi

echo Generating tar archive to $dest >&2
tar czf $dest $file_list || exit 

# Upon success, make a note of the time
touch ~/.aba.previous.backup

