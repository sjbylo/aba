#!/bin/bash 

source scripts/include_all.sh

source <(normalize-aba-conf)

[ ! "$ask" ] && exit 0  # yes

echo -n "$@ (y/N):"
read yn
[ "$yn" != "y" -a "$yn" != "Y" ] && exit 1

exit 0

