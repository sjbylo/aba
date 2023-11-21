#!/bin/bash

[ "$DEBUG_ABA" ] && set -x

DIR=`dirname $0`
cd $DIR/..

DIR=$1.src

rm -vrf ~/.cache/agent/
rm -f ~/.vmware.conf
#rm -f install-mirror/imageset*
rm -vf $DIR/install-config.yaml
rm -vf $DIR/agent-config.yaml

