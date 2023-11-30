#!/bin/bash -e

. scripts/include_all.sh

umask 077

source mirror.conf

###REMOVED mkdir install-quay
###REMOVED cd install-quay

if [ -s save/mirror_seq1_000000.tar ]; then
	echo 
	echo "WARNING: You already have images saved on local disk in $PWD/save."
	echo "         Sure you don't want to 'make load' them into the mirror registry at $reg_host?" &&
	echo -n "         Enter Return to continue ot Ctl-C to abort [y]: "
	read yn
fi

# This is a pull secret for RH registry
pull_secret_mirror_file=pull-secret-mirror.json

echo pull_secret_file=$pull_secret_file

if [ -s $pull_secret_mirror_file ]; then
	echo Using $pull_secret_mirror_file ...
elif [ -s $pull_secret_file ]; then
	#SB#ln -fs ./pull-secret.json pull-secret.json 
	:
else
	echo "Error: Your pull secret file [$pull_secret_file] does not exist! Download it from https://console.redhat.com/openshift/downloads#tool-pull-secret" && exit 1
fi


echo "Ensure dependencies installed (podman nmstate jq python3-pip j2) ..."
inst=
rpm -q --quiet jq     || inst=1

[ "$inst" ] && sudo dnf install podman jq nmstate python3-pip -y >/dev/null 2>&1

which j2 >/dev/null 2>&1 || pip3 install j2cli --user  >/dev/null 2>&1

export reg_url=https://$reg_host:$reg_port

# Can the registry mirror already be reached?
[ "$http_proxy" ] && echo "$no_proxy" | grep -q "\b$reg_host\b" || no_proxy=$no_proxy,$reg_host			  # adjust if proxy in use
#reg_code=$(curl -ILsk -o /dev/null -w "%{http_code}\n" https://$reg_host:${reg_port}/health/instance || true)
reg_code=$(curl -ILsk -o /dev/null -w "%{http_code}\n" $reg_url/health/instance || true)

##[ "$http_proxy" ] && echo "$no_proxy" | grep -q "\blocalhost\b" || no_proxy=$no_proxy,localhost 		  # adjust if proxy in use
###res_local=$(curl -ILsk -o /dev/null -w "%{http_code}\n" https://localhost:${reg_port}/health/instance || true)

# Mirror registry installed?
if [ "$reg_code" != "200" ]; then
	echo "Error: Registry at https://$reg_host:${reg_port}/ is not responding" && exit 1
fi

echo Checking registry access is working using "podman login" ...
podman login -u init -p $reg_password $reg_url --tls-verify=false 

echo Generating imageset-config.yaml for oc-mirror ...
export ocp_ver=$ocp_target_ver
export ocp_ver_major=$(echo $ocp_target_ver | cut -d. -f1-2)
j2 ./templates/imageset-config.yaml.j2 > imageset-config.yaml 

./scripts/create-containers-auth.sh

echo "Now mirroring the images.  "
echo "Ensure there is enough disk space under $HOME.  This can take 10-20 mins to complete."

# Set up script to help for manual re-sync
echo "oc mirror --config=imageset-config.yaml docker://$reg_host:$reg_port/$reg_path" > sync-mirror.sh && chmod 700 sync-mirror.sh 
./sync-mirror.sh 

#echo Generating deps/image-content-sources.yaml 
#j2 ./templates/image-content-sources.yaml.j2 > ./deps/image-content-sources.yaml
#ln -fs ./install-quay/image-content-sources.yaml ./deps

###ln -fs ~/quay-install/quay-rootCA/rootCA.pem ./deps/rootCA.pem

