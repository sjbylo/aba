#!/bin/bash -e

[ "$1" = "-d" ] && set -x

umask 077

#if [ ! -s ~/.mirror.conf ]; then
	#cp 2common/templates/mirror.conf ~/.mirror.conf
	#echo 
	#echo "Please edit the values in ~/.mirror.conf to match your environment.  Hit return key to continue or Ctr-C to abort."
	#read yn
	#vi ~/.mirror.conf
#fi

source mirror.conf

mkdir -p deps install-quay
cd install-quay

# This is a pull secret for RH registry
pull_secret_mirror_file=pull-secret-mirror.json

echo pull_secret_file=$pull_secret_file

if [ -s $pull_secret_mirror_file ]; then
	echo Using $pull_secret_mirror_file ...
elif [ -s $pull_secret_file ]; then
	ln -fs ~/.pull-secret.json pull-secret.json 
else
	echo "Error: Your pull secret file [$pull_secret_file] does not exist! Download it from https://console.redhat.com/openshift/downloads#tool-pull-secret" && exit 1
fi


echo "Ensure dependencies installed (podman nmstate jq python3-pip j2) ..."
inst=
rpm -q --quiet nmstate|| inst=1
rpm -q --quiet podman || inst=1
rpm -q --quiet jq     || inst=1

[ "$inst" ] && sudo dnf install podman jq nmstate python3-pip -y >/dev/null 2>&1

which j2 >/dev/null 2>&1 || pip3 install j2cli  >/dev/null 2>&1

# Mirror registry installed?
#if [ "$res_local" != "200" ]; then
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

set -x
	# Ensure registry dns entry exists and points to the bastion's ip
	ip=$(dig +short $reg_host)
	ip_int=$(ip route get 1 | grep -oP 'src \K\S+')

	# Host is remote 
	if [ "$ip" != "$ip_int" ]; then
		# Can the registry mirror already be reached?
		[ "$http_proxy" ] && echo "$no_proxy" | grep -q "\b$reg_host\b" || no_proxy=$no_proxy,$reg_host			  # adjust if proxy in use
		res_remote=$(curl -ILsk -o /dev/null -w "%{http_code}\n" https://$reg_host:${reg_port}/health/instance || true)

		[ $res_remote -eq 200 ] && echo "Registry already installed on host $reg_host" && exit 

		if ! ssh $(whoami)@$reg_host hostname; then
			echo "Error: Can't ssh to $(whoami)@$reg_host"
			echo "Configure ssh to the host $reg_host and try again."
			exit 1
		else
			echo "Ssh access to [$reg_host] is working ..."
		fi

		echo "Installing mirror registry on the remote host [$reg_host] with user $(whoami) ..."

		echo "Running command './mirror-registry install --quayHostname $reg_host' --targetUsername $(whoami) --quayHostname $reg_host -k ~/.ssh/id_rsa "
		./mirror-registry install -v \
		  	--targetHostname $reg_host \
		  	--targetUsername $(whoami) \
		  	--quayHostname $reg_host \
		  	-k ~/.ssh/id_rsa | tee .install.output || rm -f .install.output
		#--quayRoot <example_1directory_name>

		# Fetch root CA from remote host so the connection can be tested
		mkdir -p ~/quay-install/quay-rootCA
		scp -p $(whoami)@$reg_host:quay-install/quay-rootCA/* ~/quay-install/quay-rootCA
	else
		[ "$http_proxy" ] && echo "$no_proxy" | grep -q "\blocalhost\b" || no_proxy=$no_proxy,localhost 		  # adjust if proxy in use
		res_local=$(curl -ILsk -o /dev/null -w "%{http_code}\n" https://localhost:${reg_port}/health/instance || true)
		
		[ $res_local -eq 200 ] && echo "Registry already installed on localhost [$reg_host]" && exit 

		echo "Installing mirror registry on the localhost [$reg_host] ..."
		echo "Running command './mirror-registry install --quayHostname $reg_host'"
		./mirror-registry install --quayHostname $reg_host | tee .install.output || rm -f .install.output
		# Sample output of the above command
		# Quay is available at https://registry.lan:8443 with credentials (init, cG79mTdkAo0P3ZgLsy12VMi56NU48nla)
	fi

	if [ -s .install.output ]; then
		echo Creating json registry credentials in ~/.registry-creds.txt ...
		line=$(grep -o "Quay is available at.*" .install.output)
		reg_user=$(echo $line | awk '{print $8}' | cut -d\( -f2 | cut -d, -f1)
		reg_password=$(echo $line | awk '{print $9}' | cut -d\) -f1 )
		echo -n $reg_user:$reg_password > ~/.registry-creds.txt 
	else
		echo No install script output .install.output found. Cannot configure registry credentials. Exiting ... && exit 
	fi

	echo Allowing access to the registry port [reg_port] ...
	sudo firewall-cmd --state && sudo firewall-cmd --add-port=$reg_port/tcp  --permanent && sudo firewall-cmd --reload
#else
	###echo 
	###echo WARNING: 
	###echo "Registry detected on localhost at https://localhost:${reg_port}/health/instance"

#	echo "This script does not yet support the use of an existing registry and needs to install Quay registry on this host (bastion) itself."
#	echo "If aba installed the detected registry, then continue to use it".
#
#	if [ "$res_remote" = "200" ]; then
#		echo 
#		echo "A registry was also detected at https://$reg_host:${reg_port}/health/instance"
##	fi
#	exit 1
###fi

export reg_url=https://$reg_host:$reg_port

reg_creds=$(cat ~/.registry-creds.txt)

echo Checking registry access is working using "podman login" ...
podman login -u init -p $reg_password $reg_url --tls-verify=false 

export ocp_ver=$ocp_target_ver
export ocp_ver_major=$(echo $ocp_target_ver | cut -d. -f1-2)

echo Generating imageset-config.yaml for oc-mirror ...

j2 ../templates/imageset-config.yaml.j2 > imageset-config.yaml 

export enc_password=$(echo -n "$reg_creds" | base64 -w0)


echo Configuring ~/.docker/config.json and ~/.containers/auth.json 

mkdir -p ~/.docker ~/.containers
j2 ../templates/pull-secret-mirror.json.j2 > ../deps/pull-secret-mirror.json
ls -l ../deps/pull-secret-mirror.json $pull_secret_file 
jq -s '.[0] * .[1]' ../deps/pull-secret-mirror.json  $pull_secret_file > ../deps/pull-secret.json
cp ../deps/pull-secret.json ~/.docker/config.json
cp ../deps/pull-secret.json ~/.containers/auth.json  

# Check if the cert needs to be updated
diff ~/quay-install/quay-rootCA/rootCA.pem /etc/pki/ca-trust/source/anchors/rootCA.pem 2>/dev/null >&2|| \
	sudo cp ~/quay-install/quay-rootCA/rootCA.pem /etc/pki/ca-trust/source/anchors/ && \
	sudo update-ca-trust extract

echo 
echo Now mirroring the images.  Ensure there is enough disk space under $HOME.  This can take 10-20 mins to complete. 

### Set up script to help for manual re-sync
####echo "oc mirror --config=imageset-config.yaml docker://$reg_host:$reg_port/$reg_path" > resynch-mirror.sh && chmod 700 resynch-mirror.sh 
##./resynch-mirror.sh 

echo Generating imageContentSourcePolicy.yaml ...
###res_dir=$(ls -trd1 oc-mirror-workspace/results-* | tail -1)
###[ ! "$res_dir" ] && echo "Cannot find latest oc-mirror-workspace/results-* directory under $PWD" && exit 1
###export image_sources=$(cat $res_dir/imageContentSourcePolicy.yaml | grep -B1 -A1 $reg_host:$reg_port/$reg_path/openshift/release | sed "s/^  //")

j2 ../templates/image-content-sources.yaml.j2 > image-content-sources.yaml
ln -sf ../install-quay/image-content-sources.yaml ../deps

#export ssh_key_pub=$(cat ~/.ssh/id_rsa.pub)
#export pull_secret=$(cat pull-secret.json)
#export reg_cert=$(cat ~/quay-install/quay-rootCA/rootCA.pem)
ln -fs ~/quay-install/quay-rootCA/rootCA.pem ../deps/rootCA.pem
#echo "$image_sources" > ../deps/image-content-sources.yaml

