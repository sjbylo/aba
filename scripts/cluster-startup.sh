#!/bin/bash -ex
# Start up the cluster.  Need to uncordon to allow pods to run again.

make start 

# Use one of the methods to access the cluster
oc whoami 2>/dev/null || . <(make shell) || true
oc whoami 2>/dev/null || . <(make login)

if ! oc whoami >/dev/null; then
	echo -n Waiting for cluster to start ...
	sleep 60
	until oc whoami >/dev/null
	do
		echo -n .
		sleep 10
	done
fi
sleep 10
if ! oc whoami >/dev/null; then
	echo -n Waiting for cluster to start ...
	until oc whoami >/dev/null
	do
		echo -n .
		sleep 10
	done
fi

cluster_id=$(oc whoami --show-server | awk -F[/:] '{print $4}')
echo Cluster $cluster_id nodes:
echo
oc get nodes
echo

# Make all nodes unschedulable:
for node in $(oc get nodes -o jsonpath='{.items[*].metadata.name}'); do echo ${node} ; oc adm uncordon ${node} ; done

echo "Note the certificate expiration date of this cluster ($cluster_id):"
oc -n openshift-kube-apiserver-operator get secret kube-apiserver-to-kubelet-signer -o jsonpath='{.metadata.annotations.auth\.openshift\.io/certificate-not-after}'
echo 
