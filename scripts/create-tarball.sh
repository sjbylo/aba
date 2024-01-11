#!/bin/bash -e

[ ! "$1" ] && echo Usage: `basename $0` directory && exit 1

echo "Checking if 'aba' is directly under your homw dir..."
cd ~/aba  # make sure aba is under home dir
cd ..

echo "# Writing tar file to $1/aba-repo.tgz (use 'make tar dir=/path/to/thumbdrive' to write to your portable storage device) ..."
echo
echo "# Copy the tar file to your *internal bastion* and unpack it under your home dir with the command:"
echo "cd; tar xzvf /path/to/aba-repo.tgz"
echo
echo "# Load (and install, if needeed) the registry"
echo "make load"
echo
echo "# Create the iso and install a cluster"
echo "make cluster name=mycluster"
echo "cd mycluster; make help"

# Tar up the needed files, exclude what's not needed and bulky
tar czvf $1/aba-repo.tgz $(find bin aba -type f ! -path "aba/.git*" -a ! -path "aba/cli/*" -a ! -path "aba/mirror/mirror-registry" -a ! -path "aba/mirror/*.tar")

