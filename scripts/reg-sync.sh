#!/bin/bash -e

umask 077

source mirror.conf

mkdir -p deps install-quay
cd install-quay

# This is a pull secret for RH registry
pull_secret_mirror_file=pull-secret-mirror.json

echo pull_secret_file=$pull_secret_file

if [ -s $pull_secret_mirror_file ]; then
	echo Using $pull_secret_mirror_file ...
elif [ -s $pull_secret_file ]; then
	ln -fs ../pull-secret.json pull-secret.json 
else
	echo "Error: Your pull secret file [$pull_secret_file] does not exist! Download it from https://console.redhat.com/openshift/downloads#tool-pull-secret" && exit 1
fi


echo "Ensure dependencies installed (podman nmstate jq python3-pip j2) ..."
inst=
rpm -q --quiet jq     || inst=1

[ "$inst" ] && sudo dnf install podman jq nmstate python3-pip -y >/dev/null 2>&1

which j2 >/dev/null 2>&1 || pip3 install j2cli  >/dev/null 2>&1

# Can the registry mirror already be reached?
[ "$http_proxy" ] && echo "$no_proxy" | grep -q "\b$reg_host\b" || no_proxy=$no_proxy,$reg_host			  # adjust if proxy in use
res_remote=$(curl -ILsk -o /dev/null -w "%{http_code}\n" https://$reg_host:${reg_port}/health/instance || true)

[ "$http_proxy" ] && echo "$no_proxy" | grep -q "\blocalhost\b" || no_proxy=$no_proxy,localhost 		  # adjust if proxy in use
res_local=$(curl -ILsk -o /dev/null -w "%{http_code}\n" https://localhost:${reg_port}/health/instance || true)

# Mirror registry installed?
if [ "$res_local" != "200" ]; then
	curl -ILsk https://$reg_host:${reg_port}/health/instance 
	echo Error: Registry at https://$reg_host:${reg_port}/ not responding && exit 1
fi

export reg_url=https://$reg_host:$reg_port

set -e
echo Checking registry access is working using "podman login" ...
podman login -u init -p $reg_password $reg_url --tls-verify=false 

echo Generating imageset-config.yaml for oc-mirror ...
export ocp_ver=$ocp_target_ver
export ocp_ver_major=$(echo $ocp_target_ver | cut -d. -f1-2)
j2 ../templates/imageset-config.yaml.j2 > imageset-config.yaml 

scripts/create-containers-auth.sh

## Check if the cert needs to be updated
#diff ~/quay-install/quay-rootCA/rootCA.pem /etc/pki/ca-trust/source/anchors/rootCA.pem 2>/dev/null >&2|| \
#	sudo cp ~/quay-install/quay-rootCA/rootCA.pem /etc/pki/ca-trust/source/anchors/ && \
#	sudo update-ca-trust extract

echo 
echo Now mirroring the images.  Ensure there is enough disk space under $HOME.  This can take 10-20 mins to complete. 

# Set up script to help for manual re-sync
echo "oc mirror --config=imageset-config.yaml docker://$reg_host:$reg_port/$reg_path" > resynch-mirror.sh && chmod 700 resynch-mirror.sh 
./resynch-mirror.sh 

echo Generating imageContentSourcePolicy.yaml ...
###res_dir=$(ls -trd1 oc-mirror-workspace/results-* | tail -1)
###[ ! "$res_dir" ] && echo "Cannot find latest oc-mirror-workspace/results-* directory under $PWD" && exit 1
###export image_sources=$(cat $res_dir/imageContentSourcePolicy.yaml | grep -B1 -A1 $reg_host:$reg_port/$reg_path/openshift/release | sed "s/^  //")

j2 ../templates/image-content-sources.yaml.j2 > image-content-sources.yaml
ln -fs ../install-quay/image-content-sources.yaml ../deps

#export ssh_key_pub=$(cat ~/.ssh/id_rsa.pub)
#export pull_secret=$(cat pull-secret.json)
#export reg_cert=$(cat ~/quay-install/quay-rootCA/rootCA.pem)
ln -fs ~/quay-install/quay-rootCA/rootCA.pem ../deps/rootCA.pem
#echo "$image_sources" > ../deps/image-content-sources.yaml

