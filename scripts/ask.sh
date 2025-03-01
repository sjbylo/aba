#!/bin/bash 
# If 'ask' is set in 'aba.conf', then prompt with a message ($@)

source scripts/include_all.sh && trap - ERR 

ask $@
exit $?

