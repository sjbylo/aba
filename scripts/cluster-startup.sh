#!/bin/bash -e
# Start up the cluster.  Need to uncordon to allow pods to run again.

[ ! -d iso-agent-based ] && echo "Cluster not installed!" && exit 1
server_url=$(cat iso-agent-based/auth/kubeconfig | grep server | awk '{print $NF}' | head -1)

echo Starting cluster ...
make -s start || exit 1

echo Waiting for cluster startup ...
# Or use: timeout 3 bash -c "</dev/tcp/host/6443"
while ! curl -skI $server_url >/dev/null
do
	sleep 2
done

# Use one of the methods to access the cluster
echo Attempting to log into the cluster ...
until oc whoami >/dev/null 2>&1; do
	#. <(make -s shell) || true
	. <(make -s login) || true
	sleep 2
done

sleep 5

cluster_id=$(oc whoami --show-server | awk -F[/:] '{print $4}')
echo
echo Cluster $cluster_id nodes:
echo
oc get nodes
echo

echo "Make all nodes schedulable (uncordon):"
for node in $(oc get nodes -o jsonpath='{.items[*].metadata.name}'); do oc adm uncordon ${node} ; done
sleep 10
oc get nodes

echo
echo "Note the certificate expiration date of this cluster ($cluster_id):"
oc -n openshift-kube-apiserver-operator get secret kube-apiserver-to-kubelet-signer -o jsonpath='{.metadata.annotations.auth\.openshift\.io/certificate-not-after}'
echo 
echo "The cluster will complete startup in a short while!"
