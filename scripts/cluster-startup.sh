#!/bin/bash 
# Start up the cluster.  Need to uncordon to allow pods to run again.

source scripts/include_all.sh

[ "$1" ] && set -x

unset KUBECONFIG
cp iso-agent-based/auth.backup/kubeconfig iso-agent-based/auth/kubeconfig

[ ! -d iso-agent-based ] && echo_white "Cluster not installed!  Try running 'make clean; make' to install this cluster!" >&2 && exit 1

server_url=$(cat iso-agent-based/auth/kubeconfig | grep " server: " | awk '{print $NF}' | head -1)

cluster_name=$(echo $server_url| grep -o -E '(([a-zA-Z](-?[a-zA-Z0-9])*)\.)+[a-zA-Z]{2,}:[0-9]{2,}' | sed "s/^api\.//g")

# Check for bare-metal installation
if [ ! -s vmware.conf ]; then
	echo_yellow "Please power on all bare-metal servers for cluster '$cluster_name'." >&2

	# Quick check to see if servers are up?
	if ! try_cmd -q 1 0 2 curl --connect-timeout 10 --retry 1 -skIL $server_url; then
		# If not, then wait check for longer ...
		echo_white "Waiting for cluster endpoint $server_url to become available ..."

		# Usage: try_cmd [-q] <pause> <interval> <total>
		if ! try_cmd -q 5 0 60 curl --connect-timeout 10 --retry 1 -skIL $server_url; then
			echo_white "Giving up waiting for the cluster endpoint to become available.  Once the servers start up, please try again!" >&2
			exit 1
		fi
	fi
else
	echo Starting cluster $cluster_name ...
	make -s start #|| exit 1
fi

#echo DEBUG0 Have quick check if endpoint is available
if ! try_cmd -q 1 0 1 curl --connect-timeout 10 --retry 2 -skIL $server_url; then
	#echo DEBUG1: ret=$?
	echo Waiting for cluster endpoint $server_url ...

	# Now wait for longer...
	if ! try_cmd -q 5 0 60 curl --connect-timeout 10 --retry 3 -skIL $server_url; then
		#echo DEBUG2: ret=$?
		echo "Giving up waiting for the cluster endpoint to become available!"

		exit 1
	fi
fi

OC="oc --kubeconfig iso-agent-based/auth/kubeconfig"

# Just to be as sure as possible we can access the cluster!
#echo DEBUG3
if ! try_cmd -q 1 0 2 $OC get nodes ; then
	#echo DEBUG4
	try_cmd -q 3 0 40 $OC get nodes 
fi

echo
echo "Cluster endpoint up and accessible: $server_url"

echo
echo Cluster $cluster_name nodes:
echo
if ! $OC get nodes; then
	echo "Failed to access the cluster!" >&2

	exit 1
fi
echo

uncorden_all_nodes() { for node in $($OC get nodes -o jsonpath='{.items[*].metadata.name}'); do $OC adm uncordon ${node}; done; }

sleep 5 	# Sometimes need to wait to avoid uncordon errors

echo "Making all nodes schedulable (uncordon):"
until uncorden_all_nodes
do
	sleep 5
done

until $OC get nodes >/dev/null 2>&1
do
	sleep 10
done

echo
$OC get nodes

echo
echo "Note the certificate expiration date of this cluster ($cluster_name):"
d=$($OC -n openshift-kube-apiserver-operator get secret kube-apiserver-to-kubelet-signer -o jsonpath='{.metadata.annotations.auth\.openshift\.io/certificate-not-after}')
echo_yellow $d
echo

echo_green "The cluster will complete startup and become fully available in a short while!"

console=$($OC whoami --show-console)/
if ! try_cmd -q 1 0 2 "curl -skL $console | grep 'Red Hat OpenShift'"; then
	echo "Waiting for the console to become available at $console"

	if ! try_cmd -q 5 0 60 "curl --retry 2 -skL $console | grep 'Red Hat OpenShift'"; then
		echo Stopping
		exit 0
	fi
fi

echo_green "Cluster console is accessible at $console"

if ! try_cmd -q 1 0 2 "$OC get co --no-headers | awk '{print \$3,\$5}' | grep -v '^True False\$' | wc -l| grep '^0$'"; then
	#echo "Waiting for all cluster operators to become fully available ..."

	echo
	if ! try_cmd -q 5 0 60 "$OC get co --no-headers | awk '{print \$3,\$5}' | grep -v '^True False$' | wc -l| grep '^0$'"; then
		echo Stopping
		exit 0
	fi
fi

echo_green "All cluster operators are fully available!"

