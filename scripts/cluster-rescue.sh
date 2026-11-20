#!/bin/bash 

source scripts/include_all.sh 

# Prep execution on one node. Copy script to node and execute it there.
if [ ! "$1" = "--exec" ]; then
	aba_debug "Starting: $0 $* in $PWD"

	source <(normalize-cluster-conf) 

	verify-cluster-conf || exit 1

	ssh_id_opts=()	# set by cluster_ssh_id_opts
	if ! cluster_ssh_id_opts "$ssh_key_file"; then
		# A key in the cluster dir would ship in bundles, so the hint points outside it.
		# shellcheck disable=SC2088 # literal ~ for the user to type
		aba_info -m "No private SSH key at $ssh_key_file: ssh tries ssh-agent and the ~/.ssh default keys." \
			"If that fails, run: $(aba_cmd --ssh-key '~/.ssh/<key>')"
	fi

	if [ ! "$CLUSTER_NAME" ]; then
		scripts/cluster-config-check.sh || exit 1
		eval "$(scripts/cluster-config.sh "$@")" || exit 1
	fi

	# This will run locally and will copy and exec the rescue script (below)
	[ ! -f $ASSETS_DIR/rendezvousIP ] && aba_abort "$ASSETS_DIR/rendezvousIP file missing.  Run 'aba iso' to create it."

	ip=$(cat $ASSETS_DIR/rendezvousIP)

	ssh -F ~/.aba/ssh.conf "${ssh_id_opts[@]}" core@$ip mkdir -p scripts
	scp -F ~/.aba/ssh.conf "${ssh_id_opts[@]}" scripts/include_all.sh core@$ip:scripts
	scp -F ~/.aba/ssh.conf "${ssh_id_opts[@]}" $0 core@$ip:
	ssh -F ~/.aba/ssh.conf "${ssh_id_opts[@]}" core@$ip -- sudo bash $(basename $0) --exec


	exit $?
fi

# Now rescue the cluster ...
export KUBECONFIG=/etc/kubernetes/static-pod-resources/kube-apiserver-certs/secrets/node-kubeconfigs/localhost-recovery.kubeconfig

aba_debug "Running: oc get nodes (check SchedulingDisabled)"
if oc get nodes | grep -q SchedulingDisabled; then
	add_pause=1
	aba_info "Setting nodes scheduling enabled"
	for node in $(oc get nodes -o jsonpath='{.items[*].metadata.name}'); do aba_debug "Running: oc adm uncordon $node"; oc adm uncordon ${node} & done
	wait
else
	aba_info "No nodes set to 'SchedulingDisabled'.  Nothing to do!"
fi

aba_info "Checking if any CSRs to approve ..."
aba_debug "Running: oc get csr (check pending)"
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

aba_success "Rescue complete."

# Only pause if changes were made
[ "$add_pause" ] && sleep 20

echo
aba_info Nodes:
exec_cmd="oc get nodes"
aba_debug "Running: $exec_cmd"
$exec_cmd
echo
aba_info CSRs:
aba_debug "Running: oc get csr"
oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}'
echo
aba_info Cluster Operators:
exec_cmd="oc get co"
aba_debug "Running: $exec_cmd"
$exec_cmd

exit 0

