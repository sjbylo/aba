#!/bin/bash 

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
		fi
	fi

	[ ! "$tls_verify" ] && tls_verify_opts="--tls-verify=false"

	podman logout --all >/dev/null 
	echo "Checking registry access is working:"
	cmd="podman login $tls_verify_opts --authfile regcreds/pull-secret-mirror.json $reg_url"
	echo "Running: $cmd"
	$cmd

	echo
	echo "Valid registry credential files found in mirror/regcreds/.  Using existing registry $reg_url"

	exit 0
fi

# Mirror registry already installed?
[ "$http_proxy" ] && echo "$no_proxy" | grep -q "\b$reg_host\b" || no_proxy=$no_proxy,$reg_host		  # adjust if proxy in use
reg_code=$(curl -ILsk -o /dev/null -w "%{http_code}\n" $reg_url/ || true)

if [ "$reg_code" = "200" ]; then
	echo "Quay registry found at $reg_url/"
	echo
	echo "Warning: If this registry is your existing registry, copy this registry's pull secret and root CA (if available) files into 'mirror/regcreds/'."
	echo "See the README for instructions. "

	exit 1
fi

#reg_code=$(curl -ILsk -o /dev/null -w "%{http_code}\n" https://$reg_host:${reg_port}/health/instance || true)

exit 1
