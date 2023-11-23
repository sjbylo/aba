#!/bin/bash -e

[ ! "$1" ] && echo Usage: `basename $0` directory && exit 1
[ "$DEBUG_ABA" ] && set -x

umask 077

if [ ! -s ~/.mirror.conf ]; then
	cp common/templates/mirror.conf ~/.mirror.conf
	echo 
	echo "Please edit the values in ~/.mirror.conf to match your environment.  Hit return key to continue or Ctr-C to abort."
	read yn
	vi ~/.mirror.conf
fi
. ~/.mirror.conf

[ ! -s $pull_secret_file ] && \
	echo "Error: Your pull secret file [$pull_secret_file] does not exist! Download it from https://console.redhat.com/openshift/downloads#tool-pull-secret" && exit 1

echo Ensure dependencies installed (podman nmstate jq python3-pip j2) ...
inst=
rpm -q --quiet nmstate|| inst=1
rpm -q --quiet podman || inst=1
rpm -q --quiet jq     || inst=1

[ "$inst" ] && sudo dnf install podman jq nmstate python3-pip -y

which j2 >/dev/null 2>&1 || pip3 install j2cli 

mkdir -p install-mirror 
cd install-mirror

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
res_remote=$(curl -ILsk -o /dev/null -w "%{http_code}\n" https://$reg_host:${reg_port}/health/instance || true)
[ "$http_proxy" -o "$HTTP_PROXY" ] && no_proxy=$no_proxy,localhost   # adjust is proxy in use
res_local=$(curl -ILsk -o /dev/null -w "%{http_code}\n" https://localhost:${reg_port}/health/instance || true)

# Mirror registry installed?
if [ "$res_local" != "200" ]; then
	echo Installing Quay registry on this host ...
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
else
	echo 
	echo WARNING: 
	echo "Registry detected on localhost at https://localhost:${reg_port}/health/instance"
	echo "This script does not yet support the use of an existing registry and needs to install Quay registry on this host (bastion) itself."
	echo "If aba installed the detected registry, then continue to use it".

	if [ "$res_remote" = "200" ]; then
		echo 
		echo "A registry was also detected at https://$reg_host:${reg_port}/health/instance"
	fi
	exit 1
fi

export reg_url=https://$reg_host:$reg_port

reg_creds=$(cat ~/.registry-creds.txt)

echo Checking registry access is working using "podman login" ...
podman login -u init -p $reg_password $reg_url --tls-verify=false 

export ocp_ver=$ocp_target_ver
export ocp_ver_major=$(echo $ocp_target_ver | cut -d. -f1-2)


echo Generating imageset-config.yaml for oc-mirror ...

j2 ../common/templates/imageset-config.yaml.j2 > imageset-config.yaml 

export enc_password=$(echo -n "$reg_creds" | base64 -w0)


echo Configuring ~/.docker/config.json and ~/.containers/auth.json 

mkdir -p ~/.docker ~/.containers
j2 ../common/templates/pull-secret-mirror.json.j2 > pull-secret-mirror.json
###[ ! -s $pull_secret_file ] && echo "Error: Your pull secret file [$pull_secret_file] does not exist! Download it from https://console.redhat.com/openshift/downloads#tool-pull-secret" && exit 1
ls -l pull-secret-mirror.json $pull_secret_file 
jq -s '.[0] * .[1]' pull-secret-mirror.json  $pull_secret_file > pull-secret.json
cp pull-secret.json ~/.docker/config.json
cp pull-secret.json ~/.containers/auth.json  

# Check if the cert needs to be updated
diff ~/quay-install/quay-rootCA/rootCA.pem /etc/pki/ca-trust/source/anchors/rootCA.pem 2>/dev/null >&2|| \
	sudo cp ~/quay-install/quay-rootCA/rootCA.pem /etc/pki/ca-trust/source/anchors/ && \
	sudo update-ca-trust extract

echo 
echo Now mirroring the images.  Ensure there is enough disk space under $HOME.  This can take 10-20 mins to complete. 

# Set up script to help for manual re-sync
echo "oc mirror --config=imageset-config.yaml docker://$reg_host:$reg_port/$reg_path" > go.sh && chmod 700 go.sh 
./go.sh 

echo Generating imageContentSourcePolicy.yaml ...
res_dir=$(ls -trd1 oc-mirror-workspace/results-* | tail -1)
[ ! "$res_dir" ] && echo "Cannot find latest oc-mirror-workspace/results-* directory under $PWD" && exit 1
export image_sources=$(cat $res_dir/imageContentSourcePolicy.yaml | grep -B1 -A1 $reg_host:$reg_port/$reg_path/openshift/release | sed "s/^  //")
export ssh_key_pub=$(cat ~/.ssh/id_rsa.pub)
export pull_secret=$(cat pull-secret.json)
export reg_cert=$(cat ~/quay-install/quay-rootCA/rootCA.pem)
cp ~/quay-install/quay-rootCA/rootCA.pem . 
echo "$image_sources" > image-content-sources.yaml

echo 
echo Done $0
echo 

