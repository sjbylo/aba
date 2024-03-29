#!/bin/bash 
# Refresh the ISO

source scripts/include_all.sh

echo ==================================================================	
echo Cluster configuration
echo =====================
scripts/cluster-config.sh | sed "s/export /  /g"  | sed -e "s/=\"/=/g" -e "s/\"$//g"| tr "=" " " | column -t 
#scripts/cluster-config.sh | sed "s/^/  /g"  | sed -e "s/=\"/=/g" -e "s/\"$//g"| tr "=" " " | column -t 
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

echo 
echo "The agent based ISO has been created in the 'iso-agent-based' directory"
echo
