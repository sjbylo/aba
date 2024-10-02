#!/bin/bash

source scripts/include_all.sh

force=$1

if [ "$force" ]; then
	exit 0
else
	# The default answer is "no" (-n).  So, No = exit 1, Yes = exit 0
	ask -n "This is the same as a factory reset and will delete all files! Are you sure" && exit 1 || exit 0
fi

exit 0

