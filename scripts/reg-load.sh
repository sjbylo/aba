#!/bin/bash 

source scripts/include_all.sh

umask 077

source mirror.conf

#install_rpm podman python3-pip
install_rpm podman 
#install_pip j2cli

# Can the registry mirror already be reached?
[ "$http_proxy" ] && echo "$no_proxy" | grep -q "\b$reg_host\b" || no_proxy=$no_proxy,$reg_host			  # adjust if proxy in use
res_remote=$(curl -ILsk -o /dev/null -w "%{http_code}\n" https://$reg_host:${reg_port}/health/instance || true)

export reg_url=https://$reg_host:$reg_port

podman logout --all 
echo -n "Checking registry access to $reg_url is working using 'podman login': "
##podman login -u init -p $reg_password $reg_url 
podman login --authfile deps/pull-secret-mirror.json $reg_url 

# Run create container auth
./scripts/create-containers-auth.sh 

echo Generating imageset-config.yaml for oc-mirror ...
export ocp_ver=$ocp_target_ver
export ocp_ver_major=$(echo $ocp_target_ver | cut -d. -f1-2)
scripts/j2 ./templates/imageset-config.yaml.j2 > imageset-config.yaml 

[ "$reg_root" ] || reg_root=$HOME/quay-install  # Only needed for the below message

# Check if the cert needs to be updated
#diff $reg_root/quay-rootCA/rootCA.pem /etc/pki/ca-trust/source/anchors/rootCA.pem 2>/dev/null >&2 || \
#	sudo cp $reg_root/quay-rootCA/rootCA.pem /etc/pki/ca-trust/source/anchors/ && \
#	sudo update-ca-trust extract
diff deps/rootCA.pem /etc/pki/ca-trust/source/anchors/rootCA.pem 2>/dev/null >&2 || \
	sudo cp deps/rootCA.pem /etc/pki/ca-trust/source/anchors/ && \
	sudo update-ca-trust extract

echo 
echo Now loading the images to the registry $reg_host:$reg_port/$reg_path. 
echo Ensure there is enough disk space under $reg_root.  This can take 10-20 mins to complete. 

# Set up script to help for manual re-sync
echo "oc mirror --from=./save/mirror_seq1_000000.tar docker://$reg_host:$reg_port/$reg_path"  > upload-mirror.sh && chmod 700 upload-mirror.sh
./upload-mirror.sh


