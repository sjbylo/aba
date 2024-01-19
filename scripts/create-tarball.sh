#!/bin/bash -e

#[ ! "$1" ] && echo Usage: `basename $0` directory && exit 1

cd ..

[ "$1" ] && dir="$1" || dir=/tmp

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

# Tar up the needed files, exclude what's not needed and bulky
tar czvf $dir/aba-repo.tgz \
	$(find bin aba -type f \
		! -path "aba/.git*" -a \
		! -path "aba/cli/*" -a \
		! -path "aba/mirror/mirror-registry" -a \
		! -path "aba/mirror/*.tar" \
		! -path "aba/mirror/.installed" \
		! -path "aba/mirror/.rpms" \
		! -path "aba/mirror/.loaded" \
		! -path "aba/*/iso-agent-based*" \
	)
# Note, avoid copying any large, unneeded files, e.g. any leftover ISO agent files and the mirror-registry .tar archives

