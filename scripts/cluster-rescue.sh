#!/bin/bash 

# Prep execution on one node
if [ ! "$1" = "--exec" ]; then
	source scripts/include_all.sh 
	source <(normalize-cluster-conf) 

	# This will run locally and will copy and exec the rescue script (below)
	if [ ! -f iso-agent-based/rendezvousIP ]; then
		echo_red "Error: iso-agent-based/rendezvousIP file missing.  Run 'make' or 'make iso' to create it."

		exit 1
	fi

	ip=$(cat iso-agent-based/rendezvousIP)

	scp -i $ssh_key_file $0 core@$ip:
	ssh -i $ssh_key_file    core@$ip -- sudo bash $(basename $0) --exec

	exit $?
fi

# Now rescue the cluster ...
export KUBECONFIG=/etc/kubernetes/static-pod-resources/kube-apiserver-certs/secrets/node-kubeconfigs/localhost-recovery.kubeconfig

if oc get nodes | grep -q SchedulingDisabled; then
	echo "Setting nodes scheduling enabled"
	for node in $(oc get nodes -o jsonpath='{.items[*].metadata.name}'); do oc adm uncordon ${node} & done
else
	echo "No nodes set to 'SchedulingDisabled'"
fi

echo "Checking if any CSRs to accept ..."
until [ ! "$(oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}')" ]
do
	oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' | \
		xargs -P 5 oc adm certificate approve

	sleep 20
done
echo "Done"

sleep 20

echo Nodes:
oc get nodes
echo CSRs:
oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}'
echo Cluster Operators:
oc get co

exit 0

