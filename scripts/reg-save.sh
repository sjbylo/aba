#!/bin/bash -e

. scripts/include_all.sh

[ "$1" ] && set -x

umask 077

source mirror.conf

###REMOVED mkdir install-quay
###REMOVED cd install-quay

#### This is a pull secret for RH registry
###pull_secret_mirror_file=pull-secret-mirror.json

###echo pull_secret_file=$pull_secret_file

###if [ -s $pull_secret_mirror_file ]; then
	###echo Using $pull_secret_mirror_file ...
###elif [ -s $pull_secret_file ]; then
	####SB#ln -fs ./pull-secret.json pull-secret.json 
	###:
###else
	###echo "Error: Your pull secret file [$pull_secret_file] does not exist! Download it from https://console.redhat.com/openshift/downloads#tool-pull-secret" && exit 1
###fi

echo "Ensure dependencies installed (python3-pip j2) ..."
inst=
rpm -q --quiet jq     || inst=1

[ "$inst" ] && sudo dnf install jq -y >/dev/null 2>&1

which j2 >/dev/null 2>&1 || pip3 install j2cli --user  >/dev/null 2>&1

export ocp_ver=$ocp_target_ver
export ocp_ver_major=$(echo $ocp_target_ver | cut -d. -f1-2)

echo Generating imageset-config.yaml for saving images to local disk ...
j2 ./templates/imageset-config-save.yaml.j2 > imageset-config-save.yaml 

./scripts/create-containers-auth.sh

echo 
echo Saving images from the Internet to $PWD/save.  Ensure there is enough disk space under $PWD/save.  This can take 10-20 mins to complete. 
echo 

# Set up script to help for manual re-sync
echo "oc mirror --config=./imageset-config-save.yaml file://save" > save-mirror.sh && chmod 700 save-mirror.sh 
cat ./save-mirror.sh
./save-mirror.sh

