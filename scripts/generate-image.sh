#!/bin/bash 
# Refresh the ISO

source scripts/include_all.sh

echo ==================================================================	
echo Cluster configuration
echo =====================
scripts/cluster-config.sh | sed "s/export /  /g"  | sed -e "s/=\"/=/g" -e "s/\"$//g"| tr "=" " " | column -t 
echo ==================================================================	
eval `scripts/cluster-config.sh || exit 1`

if [ -d $MANEFEST_DIR ]; then
	echo "Backup up previous $MANEFEST_DIR' dir to '$MANEFEST_DIR.backup':"

	rm -rf $MANEFEST_DIR.backup
	cp -rp $MANEFEST_DIR $MANEFEST_DIR.backup
fi

echo Generating the ISO boot image for cluster: $CLUSTER_NAME.$BASE_DOMAIN ...

rm -rf $MANEFEST_DIR 
mkdir -p $MANEFEST_DIR

cp install-config.yaml agent-config.yaml $MANEFEST_DIR 

echo "openshift-install agent create image --dir $MANEFEST_DIR "
openshift-install agent create image --dir $MANEFEST_DIR 

echo 
echo "The agent based ISO has been created in the '$MANEFEST_DIR' directory"
echo
