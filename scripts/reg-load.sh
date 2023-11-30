#!/bin/bash -e


umask 077

source mirror.conf

###REMOVED mkdir install-quay
###REMOVED cd install-quay

### This is a pull secret for RH registry
##pull_secret_mirror_file=pull-secret-mirror.json

##echo pull_secret_file=$pull_secret_file

##if [ -s $pull_secret_mirror_file ]; then
	##echo Using $pull_secret_mirror_file ...
##elif [ -s $pull_secret_file ]; then
	###SB#ln -fs ./pull-secret.json pull-secret.json 
	##:
##else
	##echo "Error: Your pull secret file [$pull_secret_file] does not exist! Download it from https://console.redhat.com/openshift/downloads#tool-pull-secret" && exit 1
##fi


echo "Ensure dependencies installed (j2) ..."
which j2 >/dev/null 2>&1 || pip3 install j2cli  >/dev/null 2>&1

# Can the registry mirror already be reached?
[ "$http_proxy" ] && echo "$no_proxy" | grep -q "\b$reg_host\b" || no_proxy=$no_proxy,$reg_host			  # adjust if proxy in use
res_remote=$(curl -ILsk -o /dev/null -w "%{http_code}\n" https://$reg_host:${reg_port}/health/instance || true)

export reg_url=https://$reg_host:$reg_port

echo Checking registry access is working using "podman login" ...
set -e
podman login -u init -p $reg_password $reg_url --tls-verify=false 

# Run create container auth
./scripts/create-containers-auth.sh 

echo Generating imageset-config.yaml for oc-mirror ...
export ocp_ver=$ocp_target_ver
export ocp_ver_major=$(echo $ocp_target_ver | cut -d. -f1-2)
j2 ./templates/imageset-config.yaml.j2 > imageset-config.yaml 

# Check if the cert needs to be updated
diff ~/quay-install/quay-rootCA/rootCA.pem /etc/pki/ca-trust/source/anchors/rootCA.pem 2>/dev/null >&2 || \
	sudo cp ~/quay-install/quay-rootCA/rootCA.pem /etc/pki/ca-trust/source/anchors/ && \
	sudo update-ca-trust extract

echo 
echo Now loading the images to the registry $reg_host:$reg_port/$reg_path. 
echo Ensure there is enough disk space under $HOME.  This can take 10-20 mins to complete. 

# Set up script to help for manual re-sync
echo "oc mirror --from=./save/mirror_seq1_000000.tar docker://$reg_host:$reg_port/$reg_path"  > upload-mirror.sh && chmod 700 upload-mirror.sh
./upload-mirror.sh


