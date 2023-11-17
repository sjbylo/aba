#!/bin/bash

mkdir -p $1.src
[ ! -s $1.src/config.yaml ] && vi $1.src/config.yaml 
. $1.src/config.yaml

set -e
set -x

##ocp_version=4.13.19

# Ensure dependencies installed 
rpm -q podman || sudo dnf install podman  -y 
rpm -q jq     || sudo dnf install jq      -y 
rpm -q nmstate|| sudo dnf install nmstate -y 
which pip3    || sudo dnf install python3-pip -y
which j2      || pip3 install j2cli 

mkdir -p install-mirror 
cd install-mirror

#set -x
which oc 
ver_oc=$(oc version --client=true | grep "Client Version:" | awk '{print $3}')

which openshift-install 
ver_install=$(openshift-install version | grep "openshift-install" | awk '{print $2}')

echo ver_oc=$ver_oc
echo ver_install=$ver_install

if [ "$ver_oc" != "$ver_install" -o "$ver_oc" != "$ocp_version" ]; then
	echo "Warning: Missing or missmatched versions of oc ($ver_oc) and openshift-install ($ver_install)!"
	echo -n "Downlaod the latest versions and replace these binaries for version $ver_install? (y/n) [n]: "
	read yn


	if [ "$yn" = "y" ]; then
		[ ! -s openshift-client-linux-$ocp_version.tar.gz ] && \
		       	curl -OL https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/$ocp_version/openshift-client-linux-$ocp_version.tar.gz
		tar xzvf openshift-client-linux-$ocp_version.tar.gz oc
		loc_oc=$(which oc)
		mkdir -p ~/bin
		[ ! "$loc_oc" ] && loc_oc=~/bin
		sudo install oc $loc_oc

		[ ! -s openshift-install-linux-$ocp_version.tar.gz ] && \
		       	curl -OL https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/$ocp_version/openshift-install-linux-$ocp_version.tar.gz
		tar xzvf openshift-install-linux-$ocp_version.tar.gz openshift-install
		loc_installer=$(which openshift-install)
		[ ! "$loc_installer" ] && loc_installer=~/bin
		sudo install openshift-install $loc_installer

		[ ! -s oc-mirror.tar.gz ] && \
			curl -OL https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/$ocp_version/oc-mirror.tar.gz
		tar xvzf oc-mirror.tar.gz
		chmod +x oc-mirror
		sudo install oc-mirror ~/bin

	else
		echo "Doing nothing! Be warned that these versions should match!" 
	fi
fi

res=$(curl -ILsk -o /dev/null -w "%{http_code}\n" https://$reg_host:${reg_port}/health/instance || true)

# Mirror registry installed?
if [ "$res" != "200" ]; then

	./mirror-registry help || tar xzf mirror-registry.tar.gz || \
		curl -OL https://developers.redhat.com/content-gateway/rest/mirror/pub/openshift-v4/clients/mirror-registry/latest/mirror-registry.tar.gz

	./mirror-registry help || tar xzf mirror-registry.tar.gz 

	#[ ! -s mirror-registry.tar.gz ] && \
	#	curl -OL https://developers.redhat.com/content-gateway/rest/mirror/pub/openshift-v4/clients/mirror-registry/latest/mirror-registry.tar.gz

	#[ ! -s mirror-registry ] && tar xzvf mirror-registry.tar.gz 

	./mirror-registry install --quayHostname $reg_host | tee .install.output
	# Sample output 
	# Quay is available at https://registry.lan:8443 with credentials (init, cG79mTdkAo0P3ZgLsy12VMi56NU48nla)

	line=$(grep -o "Quay is available at.*" .install.output)
	reg_user=$(echo $line | awk '{print $8}' | cut -d\( -f2 | cut -d, -f1)
	reg_password=$(echo $line | awk '{print $9}' | cut -d\) -f1 )
	echo -n $reg_user:$reg_password > ~/.registry-creds.txt && chmod 600 ~/.registry-creds.txt 

	# Allow access to the registry 
	firewall-cmd --state && firewall-cmd --add-port=8443/tcp  --permanent && firewall-cmd --reload
else
	line=$(grep -o "Quay is available at.*" .install.output)
	reg_user=$(echo $line | awk '{print $8}' | cut -d\( -f2 | cut -d, -f1)
	reg_password=$(echo $line | awk '{print $9}' | cut -d\) -f1 )
	echo -n $reg_user:$reg_password > ~/.registry-creds.txt && chmod 600 ~/.registry-creds.txt 

	# DO WE WANT TO SUPPORT EXISTING MIRROR REG?
#	if [ ! -s ~/.registry-creds.txt ]; then
#		echo "Enter username and password for registry: https://$reg_host:$reg_port/"
#		echo -n "Username: "
#		read u
#		echo -n "Password: "
#		read -s p
#		echo "$u:$p" > ~/.registry-creds.txt && chmod 600 ~/.registry-creds.txt
#	fi
fi

set -x
set -e

#export reg_url=$(echo $line | awk '{print $5}')
export reg_url=https://$reg_host:$reg_port

reg_creds=$(cat ~/.registry-creds.txt)
echo reg_creds=$reg_creds
echo reg_url=$reg_url

#set +x

podman login -u init -p $reg_password $reg_url --tls-verify=false 

export ocp_ver=$ocp_version
export ocp_ver_major=$(echo $ocp_version | cut -d. -f1-2)

echo ocp_ver=$ocp_ver
echo ocp_ver_major=$ocp_ver_major

j2 ../common/templates/template-imageset-config.yaml.j2 > imageset-config.yaml 

export enc_password=$(echo -n "$reg_creds" | base64 -w0)

mkdir -p ~/.docker ~/.containers
j2 ../common/templates/template-pull-secret.json.j2 > pull-secret-mirror.json
[ ! -s $pull_secret_file ] && echo "Error: Your pull secret file [$pull_secret_file] does not exist!" && exit 1
jq -s '.[0] * .[1]' pull-secret-mirror.json  $pull_secret_file > pull-secret.json
cp pull-secret.json ~/.docker/config.json
cp pull-secret.json ~/.containers/auth.json  

# Check if the cert needs to be updated
diff ~/quay-install/quay-rootCA/rootCA.pem /etc/pki/ca-trust/source/anchors/rootCA.pem || \
	sudo cp ~/quay-install/quay-rootCA/rootCA.pem /etc/pki/ca-trust/source/anchors/ 
	sudo update-ca-trust extract

# Now mirror the images 
oc mirror --config=imageset-config.yaml docker://$reg_host:$reg_port/$reg_path

set -x
res_dir=$(ls -trd1 oc-mirror-workspace/results-* | tail -1)
[ ! "$res_dir" ] && echo "Cannot find latest oc-mirror-workspace/results-* directory under $PWD" && exit 1
export image_sources=$(cat $res_dir/imageContentSourcePolicy.yaml | grep -B1 -A1 $reg_host:$reg_port/$reg_path/openshift/release | sed "s/^  //")
export ssh_key_pub=$(cat ~/.ssh/id_rsa.pub)
export pull_secret=$(cat pull-secret.json)
export reg_cert=$(cat ~/quay-install/quay-rootCA/rootCA.pem)
cp ~/quay-install/quay-rootCA/rootCA.pem . 
echo "$image_sources" > image-content-sources.yaml

#j2 ../common/templates/install-config.yaml.j2 > install-config.yaml

