#!/bin/bash 

source scripts/include_all.sh

umask 077

source mirror.conf


# Can the registry mirror already be reached?
[ "$http_proxy" ] && echo "$no_proxy" | grep -q "\b$reg_host\b" || no_proxy=$no_proxy,$reg_host			  # adjust if proxy in use
res_remote=$(curl -ILsk -o /dev/null -w "%{http_code}\n" https://$reg_host:${reg_port}/health/instance || true)

export reg_url=https://$reg_host:$reg_port

#podman logout --all 
#echo -n "Checking registry access to $reg_url is working using 'podman login': "
###podman login -u init -p $reg_password $reg_url 
#podman login --authfile regcreds/pull-secret-mirror.json $reg_url 

# Run create container auth
./scripts/create-containers-auth.sh 

echo Generating imageset-config.yaml for oc-mirror ...
export ocp_ver=$ocp_target_ver
export ocp_ver_major=$(echo $ocp_target_ver | cut -d. -f1-2)
[ "$tls_verify" ] && export skipTLS=false || export skipTLS=true
scripts/j2 ./templates/imageset-config.yaml.j2 > imageset-config.yaml 

[ "$reg_root" ] || reg_root=$HOME/quay-install  # Only needed for the below message

# Check if the cert needs to be updated
#diff $reg_root/quay-rootCA/rootCA.pem /etc/pki/ca-trust/source/anchors/rootCA.pem 2>/dev/null >&2 || \
#	sudo cp $reg_root/quay-rootCA/rootCA.pem /etc/pki/ca-trust/source/anchors/ && \
#	sudo update-ca-trust extract
if [ -s regcreds/rootCA.pem ]; then
	if diff regcreds/rootCA.pem /etc/pki/ca-trust/source/anchors/rootCA.pem 2>/dev/null >&2; then
		sudo cp regcreds/rootCA.pem /etc/pki/ca-trust/source/anchors/ 
		sudo update-ca-trust extract
	fi
else
	echo "No regcreds/rootCA.pem cert file found (skipTLS=$skipTLS)" 
fi

echo 
echo Now loading the images to the registry $reg_host:$reg_port/$reg_path. 
echo Ensure there is enough disk space under $reg_root.  This can take 10-20 mins to complete. 

[ ! "$tls_verify" ] && tls_verify_opts="--dest-skip-tls"

# Set up script to help for manual re-sync
echo "oc mirror $tls_verify_opts --from=./save/mirror_seq1_000000.tar docker://$reg_host:$reg_port/$reg_path"  > upload-mirror.sh && chmod 700 upload-mirror.sh
./upload-mirror.sh


