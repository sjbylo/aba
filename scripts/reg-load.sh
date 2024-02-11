#!/bin/bash 

source scripts/include_all.sh

umask 077

source <(normalize-aba-conf)
source <(normalize-mirror-conf)

### # Can the registry mirror already be reached?
### [ "$http_proxy" ] && echo "$no_proxy" | grep -q "\b$reg_host\b" || no_proxy=$no_proxy,$reg_host			  # adjust if proxy in use
### res_remote=$(curl -ILsk -o /dev/null -w "%{http_code}\n" https://$reg_host:${reg_port}/health/instance || true)

export reg_url=https://$reg_host:$reg_port

### podman logout --all 
### echo -n "Checking registry access to $reg_url is working using 'podman login': "
### ##podman login -u init -p $reg_password $reg_url 
### podman login --authfile regcreds/pull-secret-mirror.json $reg_url 

# Check if the cert needs to be updated
if [ -s regcreds/rootCA.pem ]; then
	if diff regcreds/rootCA.pem /etc/pki/ca-trust/source/anchors/rootCA.pem 2>/dev/null >&2; then
		sudo cp regcreds/rootCA.pem /etc/pki/ca-trust/source/anchors/ 
		sudo update-ca-trust extract
	fi
else
	echo "No regcreds/rootCA.pem cert file found (skipTLS=$skipTLS)" 
fi

[ "$reg_root" ] || reg_root=$HOME/quay-install  # Only needed for the below message
echo 
echo Now loading the images to the registry $reg_host:$reg_port/$reg_path. 
echo Ensure there is enough disk space under $reg_root.  This can take 5-20 mins to complete. 

[ ! "$tls_verify" ] && tls_verify_opts="--dest-skip-tls"

[ ! -d save ] && echo "Warning: Missing 'mirror/save' directory" && exit 1

# Set up script to help for manual re-sync
#echo "oc mirror $tls_verify_opts --from=save docker://$reg_host:$reg_port/$reg_path"  > load-mirror.sh && chmod 700 load-mirror.sh
# --continue-on-error  needed when mirroring operator images
echo "cd save && umask 0022 && oc mirror --continue-on-error $tls_verify_opts --from=. docker://$reg_host:$reg_port/$reg_path"  > load-mirror.sh && chmod 700 load-mirror.sh
./load-mirror.sh


