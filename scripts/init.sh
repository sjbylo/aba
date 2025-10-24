#!/bin/bash 
# Initialize aba top-level dir

PREFIX=/opt/aba

source $PREFIX/scripts/include_all.sh

cp $PREFIX/templates/aba.conf .
mkdir -p mirror #FIXME: this might change

# Initial prep for interactive mode: unset ocp_version and ocp_channel
replace-value-conf aba.conf ocp_version 
replace-value-conf aba.conf ocp_channel

