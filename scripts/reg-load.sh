#!/bin/bash 

source scripts/include_all.sh

umask 077

source <(normalize-aba-conf)
source <(normalize-mirror-conf)

### # Can the registry mirror already be reached?
### [ "$http_proxy" ] && echo "$no_proxy" | grep -q "\b$reg_host\b" || no_proxy=$no_proxy,$reg_host			  # adjust if proxy in use
### res_remote=$(curl -ILsk -o /dev/null -w "%{http_code}\n" https://$reg_host:${reg_port}/health/instance || true)

export reg_url=https://$reg_host:$reg_port

### podman logout --all >/dev/null 
### echo -n "Checking registry access to $reg_url is working using 'podman login' ... "
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
echo
# Check if aba installed Quay or it's an existing reg.
if [ -s ./reg-uninstall.sh ]; then
	echo "Ensure there is enough disk space under $reg_root.  This can take 5-20+ mins to complete."
fi
echo

[ ! "$tls_verify" ] && tls_verify_opts="--dest-skip-tls"

[ ! -d save ] && echo "Error: Missing 'mirror/save' directory!  For air-gapped environments, run 'make save' first, on an Internet connected bastion/laptop" && exit 1

# Set up script to help for manual re-sync
# --continue-on-error : do not use this option. In testing the registry became unusable! 
cmd="oc mirror $tls_verify_opts --from=. docker://$reg_host:$reg_port/$reg_path"
echo "cd save && umask 0022 && $cmd"  > load-mirror.sh && chmod 700 load-mirror.sh
echo "Running: $(cat load-mirror.sh)"
if ! ./load-mirror.sh; then
	[ "$TERM" ] && tput setaf 1 
	echo "Warning: an error has occurred! Long running processes are prone to failure. Please try again!"
	[ "$TERM" ] && tput sgr0
       exit 1
fi
# If oc-mirror fails due to transient errors, the user should try again
