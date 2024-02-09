#!/bin/bash 
# This script checks to see if the needed values can be extracted from the agent-config.yaml and the install-config.yaml files.

source scripts/include_all.sh

export MANEFEST_SRC_DIR=.

ICONF=$MANEFEST_SRC_DIR/install-config.yaml  
ACONF=$MANEFEST_SRC_DIR/agent-config.yaml  

# If one of the files is missing, stop!
if [ ! -s $ICONF -o ! -s $ACONF ]; then
	echo "Cannot parse cluster configuration. 'install-config.yaml' and/or 'agent-config.yaml' do not exist."
	exit 1
fi

