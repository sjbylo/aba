#!/bin/bash 
# All configs have been completed, now create the ISO.

source scripts/include_all.sh

source <(normalize-aba-conf)
source <(normalize-mirror-conf)

verify-aba-conf || exit 1
verify-mirror-conf || exit 1

# Only use the binary from the mirror to install OCP.  For fully online installs (e.g. via proxy) reg_host is NOT defined. 
#[ "$reg_host" ] && openshift_install_mirror=./openshift-install-$ocp_version-$reg_host || openshift_install_mirror=openshift-install
openshift_install_mirror=./openshift-install-$ocp_version-$reg_host
[ ! -x "$openshift_install_mirror" ] && openshift_install_mirror=openshift-install # fallback to the regular binary

# Output the cluster configuration, to be installed.

config=$(scripts/cluster-config.sh) 
conf_display=$(echo "$config" | sed "s/export /  /g"  | sed -e "s/=\"/=/g" -e "s/\"$//g"| tr "=" " " | column -t --output-separator " | ")
len=$(echo "$conf_display" | longest_line)
printf '=%.0s' $(seq 1 "$len")
echo
echo_cyan Cluster configuration
printf '=%.0s' $(seq 1 "$len")
echo
$openshift_install_mirror version 2>&1 | cat_cyan
printf '=%.0s' $(seq 1 "$len")
echo
echo_cyan "$conf_display"
printf '=%.0s' $(seq 1 "$len")
echo

# FIXME: Use $config above? ###
#eval `scripts/cluster-config.sh || exit 1`
eval "$config || exit 1"

if [ -d $ASSETS_DIR ]; then
	echo_cyan "Backing up previous $ASSETS_DIR' dir to '$ASSETS_DIR.backup':"

	rm -rf $ASSETS_DIR.backup
	cp -rp $ASSETS_DIR $ASSETS_DIR.backup
fi

echo_cyan Generating the ISO boot image for cluster: $CLUSTER_NAME.$BASE_DOMAIN ...

rm -rf $ASSETS_DIR 
mkdir -p $ASSETS_DIR

cp install-config.yaml agent-config.yaml $ASSETS_DIR 

opts=
[ "$DEBUG_ABA" ] && opts="--log-level debug"
echo_yellow "Running: $openshift_install_mirror agent create image --dir $ASSETS_DIR "
$openshift_install_mirror agent create image --dir $ASSETS_DIR $opts

# FIXME: to implement PXE 
#$openshift_install_mirror agent create pxe-files --dir $ASSETS_DIR

echo_cyan "Making backup of '$ASSETS_DIR/auth' to '$ASSETS_DIR/auth.backup'"
cp -rp $ASSETS_DIR/auth $ASSETS_DIR/auth.backup

# Add NTP config to ignition, if needed
# Note that the built in 'additionalNTPSources' feature is not avalable for all latest ocp versions, so we use this still:
scripts/add_ntp_ignition_to_iso.sh

echo 
echo_green "The agent based ISO has been created in the '$ASSETS_DIR' directory"
echo
