#!/bin/bash

source ../scripts/include_all.sh

force=$1

if [ "$force" ]; then
	exit 0
else
	# The default answer is "no" (-n).  So, No = exit 1, Yes = exit 0
	# Always ask!
	echo_cyan -n "This is the same as a factory reset of the aba repository and will delete all files! Are you sure? (y/N): " ## && exit 1 || exit 0
	read yn
	[ "$yn" = "y" -o "$yn" = "Y" ] && exit 0
fi

exit 1

