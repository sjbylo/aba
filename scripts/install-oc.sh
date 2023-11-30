#!/bin/bash -e

. scripts/include_all.sh

umask 077

. mirror.conf

echo "Ensure dependencies installed (podman nmstate jq python3-pip j2) ..."
inst=
rpm -q --quiet nmstate|| inst=1
rpm -q --quiet podman || inst=1
rpm -q --quiet jq     || inst=1

[ "$inst" ] && sudo dnf install podman jq nmstate python3-pip -y

which j2 >/dev/null 2>&1 || pip3 install j2cli 

###REMOVED
###REMOVED

# Fetch versions of any existing oc and openshift-install binaries
which oc >/dev/null 2>&1 && oc_ver=$(oc version --client=true | grep "Client Version:" | awk '{print $3}')
which openshift-install >/dev/null 2>&1 && openshift_install_ver=$(openshift-install version | grep "openshift-install" | awk '{print $2}')

[ "$oc_ver" ] && echo "Found oc v$oc_ver" || echo "No oc found!"
[ "$openshift_install_ver" ] && echo "Found openshift-install v$openshift_install_ver" || echo "No openshift-install found!" 

if [ ! "$oc_ver" -o ! "$openshift_install_ver" -o "$oc_ver" != "$openshift_install_ver" -o "$oc_ver" != "$ocp_target_ver" ]; then
	echo "Warning: Missing or missmatched versions of oc ($oc_ver) and openshift-install ($openshift_install_ver)!"
	echo -n "Download the latest versions and replace these binaries with version $ocp_target_ver? (y/n) [n]: "
	read yn

	if [ "$yn" = "y" ]; then
		echo Installing oc version $ocp_target_ver

		mkdir -p ~/bin

		[ ! -s openshift-client-linux-$ocp_target_ver.tar.gz ] && \
		       	curl -OL https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/$ocp_target_ver/openshift-client-linux-$ocp_target_ver.tar.gz
		tar xzvf openshift-client-linux-$ocp_target_ver.tar.gz oc
		loc_oc=$(which oc || true)
		[ ! "$loc_oc" ] && loc_oc=~/bin
		sudo install oc $loc_oc
	else
		echo "Doing nothing! WARNING: versions of oc and openshift-install need to match!" 
	fi
else
	echo "oc and openshidft-install are installed and the same version."
fi


