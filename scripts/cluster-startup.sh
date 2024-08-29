#!/bin/bash 
# Start up the cluster.  Need to uncordon to allow pods to run again.

[ ! -d iso-agent-based ] && echo "Cluster not installed!" && exit 1
server_url=$(cat iso-agent-based/auth/kubeconfig | grep server | awk '{print $NF}' | head -1)

cluster_id=$(oc whoami --show-server | awk -F[/:] '{print $4}')

echo Starting cluster $cluster_id ...
make -s start || exit 1

sleep 10

echo Waiting for cluster endpoint $server_url ...
# Or use: timeout 3 bash -c "</dev/tcp/host/6443"
while ! curl -skI $server_url >/dev/null
do
	sleep 2
done

# Access the cluster ... but give up after a while
echo Attempting to log into the cluster ...
cnt=0
until oc whoami >/dev/null 2>&1; do
	. <(make -s login) 
	let cnt=$cnt+1
	[ $cnt -gt 30 ] && echo "Cannot log into the cluster.  Try to run 'make rescue' to fix the cluster." && exit 1 # Really give up!
	sleep 5
done

sleep 5

# Be sure we're logged in!  Sometimes the 2nd login can fail and "oc get nodes" (below) fails!
until oc whoami >/dev/null 2>&1; do
	. <(make -s login)
	sleep 4
done

echo
echo Cluster $cluster_id nodes:
echo
if ! oc get nodes; then
	echo "Failed to log into cluster!  Please log into the cluster and try again."
	exit 1
fi
echo

uncorden_all_nodes() { for node in $(oc get nodes -o jsonpath='{.items[*].metadata.name}'); do oc adm uncordon ${node}; sleep 5; done; }

echo "Making all nodes schedulable (uncordon):"
until uncorden_all_nodes
do
	sleep 15
done

sleep 15

oc get nodes || (sleep 10; oc get nodes)    # Sometimes the session seems to go away!

echo
echo "Note the certificate expiration date of this cluster ($cluster_id):"
oc -n openshift-kube-apiserver-operator get secret kube-apiserver-to-kubelet-signer -o jsonpath='{.metadata.annotations.auth\.openshift\.io/certificate-not-after}'
echo 
echo "The cluster will complete startup in a short while!"

