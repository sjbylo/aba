#!/bin/bash 

source scripts/include_all.sh

source <(normalize-aba-conf)

[ ! "$ask" ] && exit 0  # the default (N)

echo -n "$@ (y/N):"
read yn
[ "$yn" != "y" -a "$yn" != "Y" ] && exit 0

exit 1

