#!/bin/bash 

source scripts/include_all.sh && trap - ERR 

source <(normalize-aba-conf)

[ ! "$ask" ] && exit 0  # the default 

ask $@
exit $?

