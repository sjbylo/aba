#!/bin/bash

[ ! "$1" ] && echo Usage: `basename $0` directory && exit 1

umask 077

[ ! -s ~/.mirror.conf ] && cp common/templates/mirror.conf ~/.mirror.conf && vi ~/.mirror.conf
. ~/.mirror.conf

set -e
set -x

# Ensure dependencies installed 
inst=
rpm -q --quiet nmstate|| inst=1
rpm -q --quiet podman || inst=1
rpm -q --quiet jq     || inst=1
rpm -q --quiet nmstate|| inst=1

[ "$inst" ] && sudo dnf install podman jq nmstate python3-pip -y

which j2 || pip3 install j2cli 


mkdir -p install-mirror 
cd install-mirror

# Fetch versions of any existing oc and openshift-install binaries
which oc >/dev/null 2>&1 && ver_oc=$(oc version --client=true | grep "Client Version:" | awk '{print $3}')
which openshift-install >/dev/null 2>&1 && ver_install=$(openshift-install version | grep "openshift-install" | awk '{print $2}')

echo ver_oc=$ver_oc
echo ver_install=$ver_install

if [ ! "$ver_oc" -o ! "$ver_install" -o "$ver_oc" != "$ver_install" -o "$ver_oc" != "$ocp_target_ver" ]; then
	set +x
	echo "Warning: Missing or missmatched versions of oc ($ver_oc) and openshift-install ($ver_install)!"
	echo -n "Downlaod the latest versions and replace these binaries for version $ver_install? (y/n) [n]: "
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

		echo Installing openshift-install version $ocp_target_ver
		[ ! -s openshift-install-linux-$ocp_target_ver.tar.gz ] && \
		       	curl -OL https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/$ocp_target_ver/openshift-install-linux-$ocp_target_ver.tar.gz
		tar xzvf openshift-install-linux-$ocp_target_ver.tar.gz openshift-install
		loc_installer=$(which openshift-install || true)
		[ ! "$loc_installer" ] && loc_installer=~/bin
		sudo install openshift-install $loc_installer

		echo Installing oc-mirror version $ocp_target_ver
		[ ! -s oc-mirror.tar.gz ] && \
			curl -OL https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/$ocp_target_ver/oc-mirror.tar.gz
		tar xvzf oc-mirror.tar.gz
		chmod +x oc-mirror
		loc_ocm=$(which oc-mirror || true)
		[ ! "$loc_ocm" ] && loc_ocm=~/bin
		sudo install oc-mirror $loc_ocm 

	else
		echo "Doing nothing! WARNING: versions of oc and openshift-install need to match!" 
	fi
else
	echo "oc and openshidft-install are installed and the same version."
fi

# Can the registry mirror already be reached?
res=$(curl -ILsk -o /dev/null -w "%{http_code}\n" https://$reg_host:${reg_port}/health/instance || true)

# Mirror registry installed?
if [ "$res" != "200" ]; then
	echo Checking mirror-registry binary ...
	if [ ! -x mirror-registry ]; then
		if [ ! -s mirror-registry.tar.gz ]; then
			echo Download latest mirror-registry.tar.gz ...
			curl -OL https://developers.redhat.com/content-gateway/rest/mirror/pub/openshift-v4/clients/mirror-registry/latest/mirror-registry.tar.gz
		fi
		echo Untaring mirror-registry.tar.gz ...
		tar xzf mirror-registry.tar.gz 
	else
		echo mirror-registry binary already exists ...
	fi

	echo "Running command './mirror-registry install --quayHostname $reg_host'"
	./mirror-registry install --quayHostname $reg_host | tee .install.output
	# Sample output of the above command
	# Quay is available at https://registry.lan:8443 with credentials (init, cG79mTdkAo0P3ZgLsy12VMi56NU48nla)

	
	if [ -s .install.output ]; then
		echo Creating json registry credentials in ~/.registry-creds.txt ...
		line=$(grep -o "Quay is available at.*" .install.output)
		reg_user=$(echo $line | awk '{print $8}' | cut -d\( -f2 | cut -d, -f1)
		reg_password=$(echo $line | awk '{print $9}' | cut -d\) -f1 )
		echo -n $reg_user:$reg_password > ~/.registry-creds.txt 
	fi

	echo Allowing access to the registry port [reg_port] ...
	sudo firewall-cmd --state && sudo firewall-cmd --add-port=$reg_port/tcp  --permanent && sudo firewall-cmd --reload
#else
#	line=$(grep -o "Quay is available at.*" .install.output)
#	reg_user=$(echo $line | awk '{print $8}' | cut -d\( -f2 | cut -d, -f1)
#	reg_password=$(echo $line | awk '{print $9}' | cut -d\) -f1 )
#	echo -n $reg_user:$reg_password > ~/.registry-creds.txt && chmod 600 ~/.registry-creds.txt 
#
#	# DO WE WANT TO SUPPORT EXISTING MIRROR REG?
#	if [ ! -s ~/.registry-creds.txt ]; then
#		echo "Enter username and password for registry: https://$reg_host:$reg_port/"
#		echo -n "Username: "
#		read u
#		echo -n "Password: "
#		read -s p
#		echo "$u:$p" > ~/.registry-creds.txt && chmod 600 ~/.registry-creds.txt
#	fi
fi

export reg_url=https://$reg_host:$reg_port

reg_creds=$(cat ~/.registry-creds.txt)
#echo reg_creds=$reg_creds
#echo reg_url=$reg_url

echo Checking registry access ...
podman login -u init -p $reg_password $reg_url --tls-verify=false 

export ocp_ver=$ocp_target_ver
export ocp_ver_major=$(echo $ocp_target_ver | cut -d. -f1-2)

#echo ocp_ver=$ocp_ver
#echo ocp_ver_major=$ocp_ver_major

j2 ../common/templates/imageset-config.yaml.j2 > imageset-config.yaml 

export enc_password=$(echo -n "$reg_creds" | base64 -w0)

echo Configuring ~/.docker/config.json and ~/.containers/auth.json 
mkdir -p ~/.docker ~/.containers
j2 ../common/templates/pull-secret-mirror.json.j2 > pull-secret-mirror.json
[ ! -s $pull_secret_file ] && echo "Error: Your pull secret file [$pull_secret_file] does not exist!" && exit 1
jq -s '.[0] * .[1]' pull-secret-mirror.json  $pull_secret_file > pull-secret.json
cp pull-secret.json ~/.docker/config.json
cp pull-secret.json ~/.containers/auth.json  

# Check if the cert needs to be updated
diff ~/quay-install/quay-rootCA/rootCA.pem /etc/pki/ca-trust/source/anchors/rootCA.pem 2>/dev/null || \
	sudo cp ~/quay-install/quay-rootCA/rootCA.pem /etc/pki/ca-trust/source/anchors/ \
	sudo update-ca-trust extract

echo 
echo Mirroring the images.  Ensure there is enough space under $HOME.  This can take 10-20 mins to complete. 
oc mirror --config=imageset-config.yaml docker://$reg_host:$reg_port/$reg_path

echo Configure imageContentSourcePolicy.yaml ...
res_dir=$(ls -trd1 oc-mirror-workspace/results-* | tail -1)
[ ! "$res_dir" ] && echo "Cannot find latest oc-mirror-workspace/results-* directory under $PWD" && exit 1
export image_sources=$(cat $res_dir/imageContentSourcePolicy.yaml | grep -B1 -A1 $reg_host:$reg_port/$reg_path/openshift/release | sed "s/^  //")
export ssh_key_pub=$(cat ~/.ssh/id_rsa.pub)
export pull_secret=$(cat pull-secret.json)
export reg_cert=$(cat ~/quay-install/quay-rootCA/rootCA.pem)
cp ~/quay-install/quay-rootCA/rootCA.pem . 
echo "$image_sources" > image-content-sources.yaml


