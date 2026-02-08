#!/bin/bash 
# All configs have been completed, now create the ISO.

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

aba_debug "Loading configuration files"
source <(normalize-aba-conf)
source <(normalize-mirror-conf)

verify-aba-conf || exit 1
verify-mirror-conf || exit 1
aba_debug "Configuration validated"

# Only use the binary from the mirror to install OpenShift.  For fully online installs (e.g. via proxy/NAT) reg_host etc is NOT defined. 
#[ "$reg_host" ] && openshift_install_mirror=./openshift-install-$ocp_version-$reg_host || openshift_install_mirror=openshift-install
#openshift_install_mirror=./openshift-install-$ocp_version-$reg_host
openshift_install_mirror="./openshift-install-$ocp_version-$reg_host-$reg_port-$(echo $reg_path | tr / -)"
[ ! -x "$openshift_install_mirror" ] && openshift_install_mirror=openshift-install # fallback to the regular binary
aba_debug "openshift_install_mirror=$openshift_install_mirror"

# Output the cluster configuration, to be installed. FIXME: put into function

config=$(scripts/cluster-config.sh) 
conf_display=$(echo "$config" | grep -v "MAC_ADDRS" | sed "s/export /  /g"  | sed -e "s/=\"/=/g" -e "s/\"$//g"| tr "=" " " | column -t --output-separator " | ")
len=$(echo "$conf_display" | longest_line)
printf '=%.0s' $(seq 1 "$len")
echo
echo_cyan Cluster configuration
printf '=%.0s' $(seq 1 "$len")
echo
$openshift_install_mirror version 2>&1 | echo_cyan
printf '=%.0s' $(seq 1 "$len")
echo
echo_cyan "$conf_display"
printf '=%.0s' $(seq 1 "$len")
echo

# FIXME: Use $config above? ###
#eval `scripts/cluster-config.sh || exit 1`
eval "$config || exit 1"
aba_debug "Cluster configuration loaded: CLUSTER_NAME=$CLUSTER_NAME BASE_DOMAIN=$BASE_DOMAIN"

if [ -d $ASSETS_DIR ]; then
	aba_debug "Backing up existing $ASSETS_DIR directory"
	aba_info "Backing up previous $ASSETS_DIR' dir to '$ASSETS_DIR.backup':"

	rm -rf $ASSETS_DIR.backup
	cp -rp $ASSETS_DIR $ASSETS_DIR.backup
fi

aba_info Generating the ISO boot image for cluster: $CLUSTER_NAME.$BASE_DOMAIN ...
aba_debug "Removing old $ASSETS_DIR and creating fresh directory"

rm -rf $ASSETS_DIR 
mkdir -p $ASSETS_DIR

aba_debug "Copying install-config.yaml and agent-config.yaml to $ASSETS_DIR"
cp install-config.yaml agent-config.yaml $ASSETS_DIR 

# It is important to delete the cached image as we MUST use the image from the release payload to build the ISO.
# Avoid the scenario where we use a working cached image but not a possibly broken image from the payload (like for v4.19.18)
#rm -rf ~/.cache/agent  # Needed? FIXME

opts=
[ "$DEBUG_ABA" ] && opts="--log-level debug"
aba_debug "Running openshift-install agent create image (opts=$opts)"
echo_yellow "[ABA] Running: $openshift_install_mirror agent create image --dir $ASSETS_DIR "
if ! $openshift_install_mirror agent create image --dir $ASSETS_DIR $opts; then
	aba_debug "openshift-install failed - removing incomplete ISO"
	rm -f $ASSETS_DIR/agent.*.iso

	exit 1
fi
aba_debug "ISO generation completed successfully"

# FIXME: to implement PXE 
#$openshift_install_mirror agent create pxe-files --dir $ASSETS_DIR

aba_info "Making backup of '$ASSETS_DIR/auth' to '$ASSETS_DIR/auth.backup'"
cp -rp $ASSETS_DIR/auth $ASSETS_DIR/auth.backup

# Add NTP config to ignition, if needed
# Note that the built in 'additionalNTPSources' feature is not avalable for all latest ocp versions, so we use this still:
scripts/add_ntp_ignition_to_iso.sh

echo 
aba_info_ok "The agent based ISO has been created in the $PWD/$ASSETS_DIR directory"
