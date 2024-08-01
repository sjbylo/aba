#!/bin/bash -e
# Start up the cluster.  Need to uncordon to allow pods to run again.

echo Starting cluster ...
make -s start 

oc whoami >/dev/null 2>&1 || (echo Waiting for cluster startup; sleep 40) 

# Use one of the methods to access the cluster
while ! oc whoami >/dev/null 2>&1; do
	. <(make -s shell) || true
	. <(make -s login) || true
done

if ! oc whoami >/dev/null 2>&1; then
	echo -n Waiting for cluster to start ...
	sleep 60
	until oc whoami >/dev/null 2>&1 >/dev/null
	do
		echo -n .
		sleep 10
	done
	sleep 20
fi

cluster_id=$(oc whoami --show-server | awk -F[/:] '{print $4}')
echo Cluster $cluster_id nodes:
echo
oc get nodes
echo

echo "Make all nodes schedulable (uncordon):"
for node in $(oc get nodes -o jsonpath='{.items[*].metadata.name}'); do echo ${node} ; oc adm uncordon ${node} ; done
sleep 10
oc get nodes

echo
echo "Note the certificate expiration date of this cluster ($cluster_id):"
oc -n openshift-kube-apiserver-operator get secret kube-apiserver-to-kubelet-signer -o jsonpath='{.metadata.annotations.auth\.openshift\.io/certificate-not-after}'
echo 
echo "The cluster will complete startup in a short while!"
