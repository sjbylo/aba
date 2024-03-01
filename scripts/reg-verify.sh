#!/bin/bash 
# Try to verify access to the registry, as defined in mirror.conf

source scripts/include_all.sh

[ "$1" ] && set -x

umask 077

source <(normalize-aba-conf)
source <(normalize-mirror-conf)

reg_url=https://$reg_host:$reg_port

# Check for existing reg.creds (provided by user)
#if [ -s regcreds/rootCA.pem -a -s regcreds/pull-secret-mirror.json ]; then
if [ -s regcreds/pull-secret-mirror.json ]; then

	if [ -s regcreds/rootCA.pem ]; then
		# Check if the cert needs to be updated
		if ! sudo diff regcreds/rootCA.pem /etc/pki/ca-trust/source/anchors/rootCA-existing.pem 2>/dev/null >&2; then
			sudo cp regcreds/rootCA.pem /etc/pki/ca-trust/source/anchors/rootCA-existing.pem 
			sudo update-ca-trust extract
			echo "Cert 'regcreds/rootCA.pem' updated in system trust"
		else
			echo "regcreds/rootCA.pem already in system trust"
		fi
	else
		echo
		echo "WARNING: mirror registry pull secret file 'pull-secret-mirror.json' found in 'regcreds/' but no 'rootCA.pem' file found."
		echo

		if [ "$tls_verify" ]; then
			echo "Error: 'tls_verify' is set to '$tls_verify' in mirror.conf and no 'rootCA.pem' file exists. Copy your registry's root CA file into 'regcreds/' and try again."
			echo

			exit 1
		fi
	fi

	# Test registry access with podman 

	[ ! "$tls_verify" ] && tls_verify_opts="--tls-verify=false"

	podman logout --all >/dev/null 
	echo -n "Checking registry access is working using 'podman login' ... "
	cmd="podman login $tls_verify_opts --authfile regcreds/pull-secret-mirror.json $reg_url"
	echo "Running: $cmd"
	$cmd

	echo
	echo "Valid registry credential file(s) found in mirror/regcreds/.  Using existing registry $reg_url"

	exit 0
fi

echo
echo "Error:   No mirror registry credential files found in regcreds/"
echo "         If you want to use your existing registry, copy its pull secret file and root CA file into 'mirror/regcreds/' and try again."
echo "         The files must be named 'regcreds/pull-secret-mirror.json' and 'regcreds/rootCA.pem' respectively."
echo "         See the README.md for further instructions."
echo

exit 1

