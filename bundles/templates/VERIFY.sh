#!/bin/bash -e
# Simple script to verify the archive files (tar) 

[ "$1" = "-h" -o "$1" = "--help" ] && echo -e "Verify Aba install bundle\n\nUsage: $(basename $0)" && exit 1

cd $(dirname $0)

echo "Verifying file checksums ... (please wait!)"
cksum ocp_* > .CHECKSUM.txt
if ! diff .CHECKSUM.txt CHECKSUM.txt; then
	echo
	echo "Verification failed!  Do not use this copy of the install bundle!" >&2

	exit 1
fi

rm -f .CHECKSUM.txt
echo "Files successfully verified!"

