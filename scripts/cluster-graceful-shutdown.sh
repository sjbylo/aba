#!/bin/bash
# Attempt a cluster graceful shutdown by terminating all pods on all workers and then shutting down all nodes

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

[ "$1" = "wait=1" ] && wait=1 && shift


[ ! -s iso-agent-based/auth/kubeconfig ] && aba_abort "Cannot find iso-agent-based/auth/kubeconfig file!"

source <(normalize-aba-conf)
source <(normalize-cluster-conf)

verify-aba-conf || exit 1
verify-cluster-conf || exit 1

server_url=$(cat iso-agent-based/auth/kubeconfig | grep " server: " | awk '{print $NF}' | head -1)

aba_info Checking cluster ...
# Or use: timeout 3 bash -c "</dev/tcp/host/6443"
if ! curl --connect-timeout 10 --retry 8 -skI $server_url >/dev/null; then
	echo_red "Cluster not reachable at $server_url" >&2

	exit 1
fi

aba_info "Attempting to access the cluster ... "

# Refresh kubeconfig
unset KUBECONFIG
# Use the actual kubeconfig used after the cluster was installed, in case it was overwritten
cp iso-agent-based/auth.backup/kubeconfig  iso-agent-based/auth/kubeconfig
OC="oc --kubeconfig=iso-agent-based/auth/kubeconfig"

if ! $OC whoami >/dev/null; then
	echo_red "Error: Cannot access the cluster using iso-agent-based/auth/kubeconfig file!" >&2

	exit 1
fi

cluster_id=$($OC whoami --show-server | awk -F[/:] '{print $4}') || exit 1

aba_info Cluster $cluster_id nodes:
echo
$OC get nodes
echo

logfile=.shutdown.log
aba_info Start of shutdown $(date) > $logfile

# Preparing debug pods for gracefull shutdown (ensure all nodes are 'Ready') ...
for node in $($OC --request-timeout=30s get nodes -o jsonpath='{.items[*].metadata.name}')
do
	$OC --request-timeout=30s debug --preserve-pod node/${node} -- chroot /host hostname &
done >> $logfile 2>&1
#wait

if $OC -n openshift-kube-apiserver-operator get secret kube-apiserver-to-kubelet-signer > /dev/null; then
	cluster_exp_date=$($OC -n openshift-kube-apiserver-operator get secret kube-apiserver-to-kubelet-signer -o jsonpath='{.metadata.annotations.auth\.openshift\.io/certificate-not-after}')

	# Convert the target date to a format compatible with date command
	cluster_exp_date_seconds=$(date -d "$cluster_exp_date" +%s)

	# Get the current date in seconds since epoch
	current_date_seconds=$(date +%s)

	# Calculate the difference in seconds and then convert to days
	seconds_diff=$((cluster_exp_date_seconds - current_date_seconds))
	days_diff=$((seconds_diff / 86400))

	aba_info "Certificate expiration date of cluster: $cluster_id: $cluster_exp_date"
	echo_yellow "[ABA] The cluster certificate will expire in $days_diff days."
	aba_info "Start the cluster beforehand to ensure the cluster's CA certificate renews automatically."

else
	echo_red "Unable to discover cluster's certificate expiration date." >&2
fi

echo
aba_info -n "Gracefully shut down the cluster? (Y/n): "
read yn
[ "$yn" = "n" ] && exit 1

# wait for all debug pods to have completed successfully.
wait

aba_info "Cluster ready for gracefull shutdown!  Sending all output to $logfile ..." | tee -a $logfile

# If not SNO ...
if [ $num_masters -ne 1 -o $num_workers -ne 0 ]; then
	aba_info "Making all nodes unschedulable (corden) ..." | tee -a $logfile
	for node in $($OC get nodes -o jsonpath='{.items[*].metadata.name}')
	do
		$OC adm cordon ${node} 2>> $logfile &
	done | tee -a $logfile
	wait

	aba_info "Draining all pods from all worker nodes ..." | tee -a $logfile
	sleep 1
	for node in $($OC get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[*].metadata.name}'); 
	do
		aba_info Drain ${node}
		$OC adm drain ${node} --delete-emptydir-data --ignore-daemonsets=true --timeout=60s --force &
		# See: https://docs.redhat.com/en/documentation/openshift_container_platform/4.16/html-single/backup_and_restore/index#graceful-shutdown_graceful-shutdown-cluster
	done >> $logfile 2>&1

	wait
fi

aba_info Shutting down all nodes ... | tee -a $logfile
for node in $($OC get nodes -o jsonpath='{.items[*].metadata.name}');
do
	$OC --request-timeout=30s debug node/${node} -- chroot /host shutdown -h 1 &
done >> $logfile 2>&1

wait

echo 
aba_info_ok "All servers in the cluster will complete shutdown and power off shortly!" | tee -a $logfile

# Only wait if installed on VMs
if [ "$wait" -a -s vmware.conf ]; then
	aba_info "Waiting for all nodes to power down ..." | tee -a $logfile
	until make -s ls | grep poweredOn | wc -l | grep -q ^0$; do sleep 10; done
fi

exit 0
