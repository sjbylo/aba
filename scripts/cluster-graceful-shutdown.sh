#!/bin/bash
# Attempt a cluster graceful shutdown by terminating all pods on all workers and then shutting down all nodes

source scripts/include_all.sh

[ "$1" = "wait=1" ] && wait=1 && shift
[ "$1" ] && set -x

[ ! -s iso-agent-based/auth/kubeconfig ] && echo "Cannot find iso-agent-based/auth/kubeconfig file!" && exit 1

source <(normalize-aba-conf)
source <(normalize-cluster-conf)

server_url=$(cat iso-agent-based/auth/kubeconfig | grep " server: " | awk '{print $NF}' | head -1)

echo Checking cluster ...
# Or use: timeout 3 bash -c "</dev/tcp/host/6443"
if ! curl --connect-timeout 10 --retry 2 -skI $server_url >/dev/null; then
	echo_red "Cluster not reachable at $server_url"

	exit
fi

echo "Attempting to access the cluster ... "

# Refresh kubeconfig
unset KUBECONFIG
cp iso-agent-based/auth.backup/kubeconfig  iso-agent-based/auth/kubeconfig
OC="oc --kubeconfig=iso-agent-based/auth/kubeconfig"

if ! $OC whoami >/dev/null; then
	echo_red "Error: Cannot access the cluster using iso-agent-based/auth/kubeconfig file!"

	exit 1
fi

cluster_id=$($OC whoami --show-server | awk -F[/:] '{print $4}') || exit 1

echo Cluster $cluster_id nodes:
echo
$OC get nodes
echo

logfile=.shutdown.log
echo Start of shutdown $(date) > $logfile

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

	echo "Certificate expiration date of cluster: $cluster_id: $cluster_exp_date"
	echo_yellow "There are $days_diff days until the cluster certificate expires."
	echo "Make sure the cluster is started beforehand to allow the CA certificate to renew automatically."

else
	echo_red "Unable to discover cluster's certificate expiration date."
fi

echo
echo_cyan -n "Gracefully shut down the cluster? (Y/n): "
read yn
[ "$yn" = "n" ] && exit 1

# wait for all debug pods to have worked ok
wait

echo "Cluster ready for gracefull shutdown!  Sending all output to $logfile ..." | tee -a $logfile

#echo "Sending all output to $logfile ..." | tee -a $logfile

# If not SNO ...
if [ $num_masters -ne 1 -o $num_workers -ne 0 ]; then
	echo "Making all nodes unschedulable (corden) ..." | tee -a $logfile
	for node in $($OC get nodes -o jsonpath='{.items[*].metadata.name}')
	do
		#echo Corden ${node}
		$OC adm cordon ${node} 2>> $logfile &
	done | tee -a $logfile
	wait

	echo "Draining all pods from all worker nodes ..." | tee -a $logfile
	sleep 1
	for node in $($OC get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[*].metadata.name}'); 
	do
		echo Drain ${node}
		$OC adm drain ${node} --delete-emptydir-data --ignore-daemonsets=true --timeout=60s --force &
		# See: https://docs.redhat.com/en/documentation/openshift_container_platform/4.16/html-single/backup_and_restore/index#graceful-shutdown_graceful-shutdown-cluster
	done >> $logfile 2>&1

	wait
fi

echo Shutting down all nodes ... | tee -a $logfile
for node in $($OC get nodes -o jsonpath='{.items[*].metadata.name}');
do
	$OC --request-timeout=30s debug node/${node} -- chroot /host shutdown -h 1 &
done >> $logfile 2>&1

wait

echo 
echo_green "All servers in the cluster will complete shutdown and power off in a short while!" | tee -a $logfile

if [ "$wait" -a -s vmware.conf ]; then
	echo_cyan "Waiting for all nodes to power down ..." | tee -a $logfile
	until make -s ls | grep poweredOn | wc -l | grep -q ^0$; do sleep 10; done
fi

