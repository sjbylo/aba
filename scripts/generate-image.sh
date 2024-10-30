#!/bin/bash 
# All configs have been completed, now create the ISO.

source scripts/include_all.sh

# Output the cluster configuration, to be installed.

config=$(scripts/cluster-config.sh) 
conf_display=$(echo "$config" | sed "s/export /  /g"  | sed -e "s/=\"/=/g" -e "s/\"$//g"| tr "=" " " | column -t --output-separator " | ")
len=$(echo "$conf_display" | longest_line)
printf '=%.0s' $(seq 1 "$len")
echo
echo_cyan Cluster configuration
printf '=%.0s' $(seq 1 "$len")
echo
openshift-install version 2>&1 | cat_cyan
printf '=%.0s' $(seq 1 "$len")
echo
echo_cyan "$conf_display"
printf '=%.0s' $(seq 1 "$len")
echo

# FIXME: Use $config above? ###
#eval `scripts/cluster-config.sh || exit 1`
eval "$config || exit 1"

if [ -d $MANIFEST_DIR ]; then
	echo_cyan "Backing up previous $MANIFEST_DIR' dir to '$MANIFEST_DIR.backup':"

	rm -rf $MANIFEST_DIR.backup
	cp -rp $MANIFEST_DIR $MANIFEST_DIR.backup
fi

echo_cyan Generating the ISO boot image for cluster: $CLUSTER_NAME.$BASE_DOMAIN ...

rm -rf $MANIFEST_DIR 
mkdir -p $MANIFEST_DIR

cp install-config.yaml agent-config.yaml $MANIFEST_DIR 

echo_cyan "openshift-install agent create image --dir $MANIFEST_DIR "
openshift-install agent create image --dir $MANIFEST_DIR 

# FIXME: to implement PXE 
#openshift-install agent create pxe-files --dir $MANIFEST_DIR

echo_cyan "Making backup of '$MANIFEST_DIR/auth' to '$MANIFEST_DIR/auth.backup'"
cp -rp $MANIFEST_DIR/auth $MANIFEST_DIR/auth.backup

# Add NTP config to ignition, if needed
scripts/add_ntp_ignition_to_iso.sh

echo 
echo_green "The agent based ISO has been created in the '$MANIFEST_DIR' directory"
echo
