#!/bin/bash
# Attempt a cluster graceful shutdown by terminating all pods on all workers and then shutting down all nodes

source scripts/include_all.sh

[ "$1" ] && set -x

source <(normalize-cluster-conf)

[ ! -s iso-agent-based/auth/kubeconfig ] && echo "Cannot find iso-agent-based/auth/kubeconfig file!" && exit 1
server_url=$(cat iso-agent-based/auth/kubeconfig | grep server | awk '{print $NF}' | head -1)

echo Checking cluster ...
# Or use: timeout 3 bash -c "</dev/tcp/host/6443"
if ! curl --connect-timeout 10 --retry 2 -skI $server_url >/dev/null; then
	echo "Cluster not reachable at $server_url"

	exit
fi

echo "Attempting to log into the cluster ... "

# Refresh kubeconfig
unset KUBECONFIG
cp iso-agent-based/auth.backup/kubeconfig  iso-agent-based/auth/kubeconfig
OC="oc --kubeconfig=iso-agent-based/auth/kubeconfig"

if ! $OC whoami; then
	echo_red "Error: Cannot access the cluster using iso-agent-based/auth/kubeconfig file!"

	exit 1
fi

cluster_id=$($OC whoami --show-server | awk -F[/:] '{print $4}') || exit 1

echo Cluster $cluster_id nodes:
echo
$OC get nodes
echo

if $OC -n openshift-kube-apiserver-operator get secret kube-apiserver-to-kubelet-signer > /dev/null; then
	cluster_exp_date=$($OC -n openshift-kube-apiserver-operator get secret kube-apiserver-to-kubelet-signer -o jsonpath='{.metadata.annotations.auth\.openshift\.io/certificate-not-after}')

	# Convert the target date to a format compatible with date command
	cluster_exp_date_seconds=$(date -d "$cluster_exp_date" +%s)

	# Get the current date in seconds since epoch
	current_date_seconds=$(date +%s)

	# Calculate the difference in seconds and then convert to days
	seconds_diff=$((cluster_exp_date_seconds - current_date_seconds))
	days_diff=$((seconds_diff / 86400))

	echo "Certificate expiration date of cluster: $cluster_id: $cluster_exp_date"
	echo "There are $days_diff days until the cluster certificate expires. Ensure to start the cluster before then for the certificate to be automatically renewed."

else
	echo_red "Unable to discover cluster's certificate expiration date."
fi

echo
echo -n "Shutdown the cluster? (Y/n): "
read yn
[ "$yn" = "n" ] && exit 1

logfile=.shutdown.log
echo "Logging all output to log file: $logfile ..." | tee $logfile

echo "Preparing cluster for gracefull shutdown (ensure all nodes are 'Ready') ..." | tee -a $logfile
for node in $($OC --request-timeout=30s get nodes -o jsonpath='{.items[*].metadata.name}')
do
	$OC --request-timeout=30s debug -q --preserve-pod node/${node} -- chroot /host whoami &
done >> $logfile 2>&1
wait

# If not SNO ...
if [ $num_masters -ne 1 -o $num_workers -ne 0 ]; then
	echo "Making all nodes unschedulable (corden) ..." | tee -a $logfile
	for node in $($OC get nodes -o jsonpath='{.items[*].metadata.name}')
	do
		echo Uncorden ${node}
		$OC adm cordon ${node} &
	done >> $logfile 2>&1
	wait

	echo "Draining all pods from all worker nodes ..." | tee -a $logfile
	sleep 1
	for node in $($OC get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[*].metadata.name}'); 
	do
		echo Drain ${node}
		#$OC adm drain ${node} --delete-emptydir-data --ignore-daemonsets=true --timeout=60s --force&
		$OC adm drain ${node} --delete-emptydir-data --ignore-daemonsets=true --timeout=60s        &
		# See: https://docs.redhat.com/en/documentation/openshift_container_platform/4.16/html-single/backup_and_restore/index#graceful-shutdown_graceful-shutdown-cluster
	done >> $logfile 2>&1
	wait
fi

echo Shutting down all nodes ... | tee -a $logfile
for node in $($OC get nodes -o jsonpath='{.items[*].metadata.name}');
do
	$OC --request-timeout=30s debug node/${node} -- chroot /host shutdown -h 1
done >> $logfile 2>&1

echo 
echo "The cluster will complete shutdown and power off in a short while!" | tee -a $logfile

