#!/bin/bash 
# Load the registry with images from the local disk

source scripts/include_all.sh

try_tot=1  # def. value
[ "$1" == "y" ] && set -x && shift  # If the debug flag is "y"
[ "$1" ] && [ $1 -gt 0 ] && try_tot=`expr $1 + 1` && echo "Will try $try_tot times."    # If the retry value exists and it's a number

umask 077

source <(normalize-aba-conf)
source <(normalize-mirror-conf)

### # Can the registry mirror already be reached?
### [ "$http_proxy" ] && echo "$no_proxy" | grep -q "\b$reg_host\b" || no_proxy=$no_proxy,$reg_host			  # adjust if proxy in use
### res_remote=$(curl --retry 3 -ILsk -o /dev/null -w "%{http_code}\n" https://$reg_host:${reg_port}/health/instance || true)

export reg_url=https://$reg_host:$reg_port

scripts/create-containers-auth.sh --load   # --load option indicates that the public pull secret is NOT needed.

# Check if the cert needs to be updated
if [ -s regcreds/rootCA.pem ]; then
	if diff regcreds/rootCA.pem /etc/pki/ca-trust/source/anchors/rootCA.pem 2>/dev/null >&2; then
		sudo cp regcreds/rootCA.pem /etc/pki/ca-trust/source/anchors/ 
		sudo update-ca-trust extract
	fi
else
	echo "No regcreds/rootCA.pem cert file found (skipTLS=$skipTLS)" 
fi

[ "$reg_root" ] || reg_root=$HOME/quay-install  # $reg_root is needed for the below message

[ ! "$tls_verify" ] && tls_verify_opts="--dest-skip-tls"

if [ ! -d save ]; then
	echo_red "Error: Missing 'mirror/save' directory!  For air-gapped environments, run 'make save' first on an external (Internet connected) bastion/laptop"

	exit 1
fi

echo 
echo Now loading the images to the registry $reg_host:$reg_port/$reg_path. 
echo

# Check if aba installed Quay or it's an existing reg.
if [ -s ./reg-uninstall.sh ]; then
	echo "Warning: Ensure there is enough disk space under $reg_root.  This can take 5-20+ mins to complete or even longer if Operator images are being loaded!"
fi
echo

# Set up script to help for manual re-sync
# --continue-on-error : do not use this option. In testing the registry became unusable! 
# Note: If 'make save/load/sync' fail with transient errors, the command must be re-run until it succeeds!
cmd="oc mirror $tls_verify_opts --from=. docker://$reg_host:$reg_port/$reg_path"
echo "cd save && umask 0022 && $cmd"  > load-mirror.sh && chmod 700 load-mirror.sh

try=1
failed=1
while [ $try -le $try_tot ]
do
	echo_magenta -n "Attempt ($try/$try_tot)."
	[ $try_tot -le 1 ] && echo_white " Set number of retries with 'make load retry=<number>'" || echo
	echo "Running: $(cat load-mirror.sh)"
	echo

	./load-mirror.sh && failed= && break

	echo_red "Warning: Long-running processes may fail. Resolve any issues if needed, otherwise, try again."

	let try=$try+1
done

[ "$failed" ] && echo_red "Image loading aborted ..." && exit 1

echo
echo_green "Images loaded successfully!"
echo 
echo "OpenShift can now be installed with the command:"
echo "  cd aba"
echo "  make cluster name=mycluster [type=sno|compact|standard]   # and follow the instructions."

exit 0
