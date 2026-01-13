#!/bin/bash 

source scripts/include_all.sh 

# Prep execution on one node. Copy script to node and execute it there.
if [ ! "$1" = "--exec" ]; then
	aba_debug "Starting: $0 $*"

	source <(normalize-cluster-conf) 

	verify-cluster-conf || exit 1

	if [ ! "$CLUSTER_NAME" ]; then
		scripts/cluster-config-check.sh
		eval $(scripts/cluster-config.sh $@ || exit 1)
	fi

	# This will run locally and will copy and exec the rescue script (below)
	[ ! -f $ASSETS_DIR/rendezvousIP ] && aba_abort "Error: $ASSETS_DIR/rendezvousIP file missing.  Run 'aba iso' to create it."

	ip=$(cat $ASSETS_DIR/rendezvousIP)

        ssh -F ~/.aba/ssh.conf -i $ssh_key_file core@$ip mkdir -p scripts
        scp -i $ssh_key_file scripts/include_all.sh core@$ip:scripts
        scp -i $ssh_key_file $0 core@$ip:
        ssh -F ~/.aba/ssh.conf -i $ssh_key_file core@$ip -- sudo bash $(basename $0) --exec


	exit $?
fi

# Now rescue the cluster ...
export KUBECONFIG=/etc/kubernetes/static-pod-resources/kube-apiserver-certs/secrets/node-kubeconfigs/localhost-recovery.kubeconfig

if oc get nodes | grep -q SchedulingDisabled; then
	add_pause=1
	aba_info "Setting nodes scheduling enabled"
	for node in $(oc get nodes -o jsonpath='{.items[*].metadata.name}'); do oc adm uncordon ${node} & done
	wait
else
	aba_info "No nodes set to 'SchedulingDisabled'.  Nothing to do!"
fi

aba_info "Checking if any CSRs to approve ..."
if [ "$(oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}')" ]; then
	add_pause=1
	until [ ! "$(oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}')" ]
	do
		oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' | \
			xargs -P 5 oc adm certificate approve
	
		sleep 30 # This is the time we wait to see if there are any more CSRs to approve
	done
else
	aba_info "No CSRs exist. Nothing to do!" 
fi

aba_info_ok "Rescue complete."

# Only pause if changes were made
[ "$add_pause" ] && sleep 20

echo
aba_info Nodes:
oc get nodes
echo
aba_info CSRs:
oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}'
echo
aba_info Cluster Operators:
oc get co

exit 0

