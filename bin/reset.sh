#!/bin/bash

[ ! "$1" ] && echo Usage: `basename $0` --dir directory && exit 1
[ "$DEBUG_ABA" ] && set -x

DIR=`dirname $0`
cd $DIR/..

[ "$1" ] && DIR=$1.src

#rm -vrf ~/.cache/agent/ ~/.vmware.conf ~/.mirror.conf 
rm -vrf ~/.cache/agent/ ~/.vmware.conf 

[ "$DIR" ] && rm -vf $DIR/install-config.yaml $DIR/agent-config.yaml

