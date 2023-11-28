#!/bin/bash -e

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

## Can the registry mirror already be reached?
#[ "$http_proxy" ] && echo "$no_proxy" | grep -q "\b$reg_host\b" || no_proxy=$no_proxy,$reg_host			  # adjust if proxy in use
#res_remote=$(curl -ILsk -o /dev/null -w "%{http_code}\n" https://$reg_host:${reg_port}/health/instance || true)
#
#[ "$http_proxy" ] && echo "$no_proxy" | grep -q "\blocalhost\b" || no_proxy=$no_proxy,localhost 		  # adjust if proxy in use
#res_local=$(curl -ILsk -o /dev/null -w "%{http_code}\n" https://localhost:${reg_port}/health/instance || true)

set -x


export reg_url=https://$reg_host:$reg_port

reg_creds=$(cat ~/.registry-creds.txt)

echo Checking registry access is working using "podman login" ...
###podman login -u init -p $reg_password $reg_url --tls-verify=false 

export ocp_ver=$ocp_target_ver
export ocp_ver_major=$(echo $ocp_target_ver | cut -d. -f1-2)

echo Generating imageset-config.yaml for oc-mirror ...

j2 ../templates/imageset-config.yaml.j2 > imageset-config.yaml 

export enc_password=$(echo -n "$reg_creds" | base64 -w0)

echo Configuring ~/.docker/config.json and ~/.containers/auth.json 

mkdir -p ~/.docker ~/.containers
j2 ../templates/pull-secret-mirror.json.j2 > ../deps/pull-secret-mirror.json
# Merge the two json files
ls -l ../deps/pull-secret-mirror.json $pull_secret_file 
jq -s '.[0] * .[1]' ../deps/pull-secret-mirror.json  $pull_secret_file > ../deps/pull-secret.json
cp ../deps/pull-secret.json ~/.docker/config.json
cp ../deps/pull-secret.json ~/.containers/auth.json  

## Check if the cert needs to be updated
#diff ~/quay-install/quay-rootCA/rootCA.pem /etc/pki/ca-trust/source/anchors/rootCA.pem 2>/dev/null >&2|| \
#	sudo cp ~/quay-install/quay-rootCA/rootCA.pem /etc/pki/ca-trust/source/anchors/ && \
#	sudo update-ca-trust extract

echo 
echo Now staging the images to $PWD/stage.  Ensure there is enough disk space under $HOME.  This can take 10-20 mins to complete. 

# Set up script to help for manual re-sync
##echo "oc mirror --config=imageset-config.yaml docker://$reg_host:$reg_port/$reg_path" > resynch-mirror.sh && chmod 700 resynch-mirror.sh 
#echo "oc mirror --config=./imageset-config.yaml file://stage" > stage-mirror.sh && chmod 700 stage-mirror.sh 

echo "oc mirror --from=./stage/mirror_seq1_000000.tar docker://$reg_host:$reg_port/$reg_path"  > upload.sh && chmod 700 upload.sh
##./resynch-mirror.sh 
#./stage-mirror.sh
./upload.sh

###j2 ../templates/image-content-sources.yaml.j2 > image-content-sources.yaml
###ln -s ../install-quay/image-content-sources.yaml ../deps

