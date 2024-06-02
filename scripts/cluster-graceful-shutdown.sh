#!/bin/bash -e
# Attenpt a cluster graceful shutdown by terminating all pods on all nodes

cluster_id=$(oc whoami --show-server | awk -F[/:] '{print $4}') || exit 1
echo Cluster $cluster_id nodes:
echo
oc get nodes
echo

echo "Certificate expiration date of cluster: $cluster_id:"
oc -n openshift-kube-apiserver-operator get secret kube-apiserver-to-kubelet-signer -o jsonpath='{.metadata.annotations.auth\.openshift\.io/certificate-not-after}'
echo
echo -n "Shutdown the cluster? (Y/n): "
read yn
[ "$yn" = "n" ] && exit 1

echo Enabling debug for all nodes:
for node in $(oc get nodes -o jsonpath='{.items[*].metadata.name}'); do oc debug node/${node} -- chroot /host whoami & done 
wait

echo Makeing all nodes unschedulable (corden):
for node in $(oc get nodes -o jsonpath='{.items[*].metadata.name}'); do echo ${node} ; oc adm cordon ${node} & done 
wait

echo Draining all pods:
for node in $(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[*].metadata.name}'); do echo ${node} ; oc adm drain ${node} --delete-emptydir-data --ignore-daemonsets=true --timeout=90s & done
wait

###for node in $(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[*].metadata.name}'); do echo ${node} ; oc adm drain ${node} --delete-emptydir-data --ignore-daemonsets=true --force --disable-eviction --timeout=20s; done || true
 
echo Stopping all nodes:
make stop

##set -x
## Shut down all of the nodes
#for node in $(oc get nodes -o jsonpath='{.items[*].metadata.name}'); do oc --request-timeout=20s debug node/${node} -- chroot /host shutdown -h 1; done || make stop

