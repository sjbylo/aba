#!/bin/bash -e
# Refresh the ISO

source scripts/include-trap.sh

echo ===================
scripts/cluster-config.sh 
echo ===================
eval `scripts/cluster-config.sh || exit 1`

echo Generating the ISO image for $CLUSTER_NAME.$BASE_DOMAIN ...

rm -rf agent-based 
mkdir -p agent-based

cp -v install-config.yaml agent-config.yaml $MANEFEST_DIR 

rm -rf $MANEFEST_DIR.backup
cp -rp $MANEFEST_DIR $MANEFEST_DIR.backup

echo "openshift-install agent create image --dir $MANEFEST_DIR "
openshift-install agent create image --dir $MANEFEST_DIR 

