#!/bin/bash -e
# Refresh the ISO

. scripts/include_all.sh

echo ==================================================================	
echo Cluster configuration
echo =====================
scripts/cluster-config.sh | sed "s/export /  /g" 
echo ==================================================================	
eval `scripts/cluster-config.sh || exit 1`

echo Generating the ISO image for $CLUSTER_NAME.$BASE_DOMAIN ...

rm -rf iso-agent-based 
mkdir -p iso-agent-based

cp install-config.yaml agent-config.yaml $MANEFEST_DIR 

rm -rf $MANEFEST_DIR.backup
cp -rp $MANEFEST_DIR $MANEFEST_DIR.backup

echo "openshift-install agent create image --dir $MANEFEST_DIR "
openshift-install agent create image --dir $MANEFEST_DIR 

