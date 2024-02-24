#!/bin/bash -e

cd ..

[ "$1" ] && dir="$1" || dir=/tmp

if [ "$dir" != "-" ]; then
	dest=$dir/aba-repo.tgz 

	echo "Writing tar file"
	echo
	echo "After the tar file has been written, copy the tar file to your *internal bastion* and"
	echo "extract it under your home directory with the command:"
	echo "cd; tar xzvf /path/to/aba-repo.tgz"
	echo
	echo "Load (and install, if needeed) the registry"
	echo "make load"
	echo
	echo "Create the iso and install a cluster"
	echo "make cluster name=mycluster"
	echo "cd mycluster; make help"
	echo
	echo "Writing tar file to $dir/aba-repo.tgz (use 'make tar out=/path/to/thumbdrive' to write to your portable storage device) ..."
else
	dest="-"
fi

tar czf $dest \
	$(find \
		bin \
		aba/aba \
		aba/aba.conf \
		aba/Makefile \
		aba/mirror \
		aba/others \
		aba/README.md \
		aba/README-OTHER.md \
		aba/scripts \
		aba/templates \
		aba/Troubleshooting.md \
		aba/vmware.conf \
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
		! -path "aba/mirror/quay.tar" 			\
		! -path "aba/mirror/pause.tar" 			\
		! -path "aba/mirror/postgres.tar" 		\
		! -path "aba/mirror/redis.tar" 			\
		! -path "aba/*/iso-agent-based*" \
	)

# Note, avoid copying any large, unneeded files, e.g. any leftover ISO agent files and the mirror-registry .tar archives

