#!/bin/bash -e
# Simple script to verify and unpack the archive files (tar) 

[ "$1" = "-h" -o "$1" = "--help" ] && echo -e "Unpack Aba install bundle\n\nUsage: $(basename $0) [directory]      - Optional destination directory" && exit 1

dir=.
[ "$1" ] && dir="$1"

echo Extracting files into directory: [$dir] ...
cat ocp_* | tar -C "$dir" -xvf -

echo
echo "Success! Aba extracted to dir: '$dir'"

echo
echo "Now run these commands and follow the instructions or see https://github.com/sjbylo/aba.git:"
echo "$ cd $dir/aba" | tr -s /
echo "$ ./install"
echo "$ aba"

