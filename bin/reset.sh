#!/bin/bash

[ "$DEBUG_ABA" ] && set -x

DIR=`dirname $0`
cd $DIR/..

[ "$1" ] && DIR=$1.src

rm -vrf ~/.cache/agent/ ~/.vmware.conf ~/.mirror.conf 

[ "$DIR" ] && rm -vf $DIR/install-config.yaml $DIR/agent-config.yaml

