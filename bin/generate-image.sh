#!/bin/bash -e

[ ! "$1" ] && echo Usage: `basename $0` --dir directory && exit 1
[ "$DEBUG_ABA" ] && set -x

eval `common/scripts/cluster-config.sh $@ || exit 1`

echo Generating the ISO image for $CLUSTER_NAME.$BASE_DOMAIN ...

rm -rf $MANEFEST_DIR && cp -rp $MANEFEST_SRC_DIR $MANEFEST_DIR && \
openshift-install agent create image --log-level debug --dir $MANEFEST_DIR 

