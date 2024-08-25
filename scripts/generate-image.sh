#!/bin/bash 
# Refresh the ISO

source scripts/include_all.sh

config=$(scripts/cluster-config.sh) 
output=$(echo "$config" | sed "s/export /  /g"  | sed -e "s/=\"/=/g" -e "s/\"$//g"| tr "=" " " | column -t --output-separator " | ")
len=$(echo "$output" | longest_line)
printf '=%.0s' $(seq 1 "$len")
echo
echo Cluster configuration
printf '=%.0s' $(seq 1 "$len")
echo
echo "$output"
printf '=%.0s' $(seq 1 "$len")
echo

# FIXME: Use $config above? ###
eval `scripts/cluster-config.sh || exit 1`

if [ -d $MANIFEST_DIR ]; then
	echo "Backup up previous $MANIFEST_DIR' dir to '$MANIFEST_DIR.backup':"

	rm -rf $MANIFEST_DIR.backup
	cp -rp $MANIFEST_DIR $MANIFEST_DIR.backup
fi

echo Generating the ISO boot image for cluster: $CLUSTER_NAME.$BASE_DOMAIN ...

rm -rf $MANIFEST_DIR 
mkdir -p $MANIFEST_DIR

cp install-config.yaml agent-config.yaml $MANIFEST_DIR 

echo "openshift-install agent create image --dir $MANIFEST_DIR "
openshift-install agent create image --dir $MANIFEST_DIR 

# FIXME: to implement PXE 
#openshift-install agent create pxe-files --dir $MANIFEST_DIR

echo "Making backup of '$MANIFEST_DIR/auth' to '$MANIFEST_DIR/auth.backup'"
cp -rp $MANIFEST_DIR/auth $MANIFEST_DIR/auth.backup

echo 
echo "The agent based ISO has been created in the '$MANIFEST_DIR' directory"
echo
