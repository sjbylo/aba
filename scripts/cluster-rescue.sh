#!/bin/bash 

# Prep execution on one node
if [ ! "$1" = "--exec" ]; then
	source scripts/include_all.sh 

	aba_debug "Starting: $0 $*"

	source <(normalize-cluster-conf) 

	verify-cluster-conf || exit 1

	# This will run locally and will copy and exec the rescue script (below)
	if [ ! -f iso-agent-based/rendezvousIP ]; then
		echo_red "Error: iso-agent-based/rendezvousIP file missing.  Run 'aba' or 'aba iso' to create it." >&2

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
	add_pause=1
	echo "Setting nodes scheduling enabled"
	for node in $(oc get nodes -o jsonpath='{.items[*].metadata.name}'); do oc adm uncordon ${node} & done
	wait
else
	echo "No nodes set to 'SchedulingDisabled'.  Nothing to do!"
fi

echo "Checking if any CSRs to approve ..."
if [ "$(oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}')" ]; then
	add_pause=1
	until [ ! "$(oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}')" ]
	do
		oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' | \
			xargs -P 5 oc adm certificate approve
	
		sleep 30 # This is the time we wait to see if there are any more CSRs to approve
	done
else
	echo "No CSRs exist. Nothing to do!" 
fi

echo "Rescue complete."

# Only pause if changes were made
[ "$add_pause" ] && sleep 20

echo
echo Nodes:
oc get nodes
echo
echo CSRs:
oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}'
echo
echo Cluster Operators:
oc get co

exit 0

