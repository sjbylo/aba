#!/bin/bash 
# Attempt a cluster graceful shutdown by terminating all pods on all workers and then shutting down all nodes

source scripts/include_all.sh

[ "$1" ] && set -x

source <(normalize-cluster-conf)

[ ! -s iso-agent-based/auth/kubeconfig ] && echo "Cannot find iso-agent-based/auth/kubeconfig file!" && exit 1
server_url=$(cat iso-agent-based/auth/kubeconfig | grep server | awk '{print $NF}' | head -1)

echo "Sending all output to $cluster_id.shutdown.log"
echo Checking cluster ...
# Or use: timeout 3 bash -c "</dev/tcp/host/6443"
if ! curl --retry 2 -skI $server_url >/dev/null; then
	echo "Cluster not reachable at $server_url"

	exit
fi

exec >> .$cluster_id.shutdown.log 2>&1
exec 3> /dev/tty

echo "Attempting to log into the cluster ... " >&3

OC="oc --kubeconfig=iso-agent-based/auth/kubeconfig"

if ! $OC whoami; then
	echo_red "Error: Cannot access the cluster using iso-agent-based/auth/kubeconfig file!"

	exit 1
fi

cluster_id=$($OC whoami --show-server | awk -F[/:] '{print $4}') || exit 1
echo Cluster $cluster_id nodes: >&3
echo >&3
$OC get nodes >&3
echo >&3

if $OC -n openshift-kube-apiserver-operator get secret kube-apiserver-to-kubelet-signer > /dev/null; then
	cluster_exp_date=$($OC -n openshift-kube-apiserver-operator get secret kube-apiserver-to-kubelet-signer -o jsonpath='{.metadata.annotations.auth\.openshift\.io/certificate-not-after}')

	# Convert the target date to a format compatible with date command
	cluster_exp_date_seconds=$(date -d "$cluster_exp_date" +%s)

	# Get the current date in seconds since epoch
	current_date_seconds=$(date +%s)

	# Calculate the difference in seconds and then convert to days
	seconds_diff=$((cluster_exp_date_seconds - current_date_seconds))
	days_diff=$((seconds_diff / 86400))

	echo "Certificate expiration date of cluster: $cluster_id: $cluster_exp_date" >&3
	echo "There are $days_diff days until the cluster certificate expires. Ensure to start the cluster before then for the certificate to be automatically renewed." >&3

else
	echo "Cannot discover cluster's certificate expiration date." >&3
fi

echo >&3
echo -n "Shutdown the cluster? (Y/n): " >&3
read yn
[ "$yn" = "n" ] && exit 1

echo "Priming debug pods for all nodes (ensure all nodes are 'Ready'):" >&3
for node in $($OC --request-timeout=20s get nodes -o jsonpath='{.items[*].metadata.name}'); do $OC --request-timeout=20s debug -q --preserve-pod node/${node} -- chroot /host whoami > .$cluster_id.shutdown.log 2>&1 & done 
wait

# If not SNO ...
if [ $num_masters -ne 1 -o $num_workers -ne 0 ]; then
	echo "Making all nodes unschedulable (corden):" >&3
	for node in $($OC get nodes -o jsonpath='{.items[*].metadata.name}'); do echo Uncorden ${node} ; $OC adm cordon ${node} > .$cluster_id.shutdown.log 2>&1 & done 
	wait

	echo "Draining all pods from all worker nodes (logging to .$cluster_id.shutdown.log):"
	sleep 1
	for node in $($OC get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[*].metadata.name}'); 
	do
		echo Drain ${node}
		$OC adm drain ${node} --delete-emptydir-data --ignore-daemonsets=true --timeout=120s >> .$cluster_id.shutdown.log 2>&1 &
	done
	wait
fi

echo Shutting down all nodes:
for node in $($OC get nodes -o jsonpath='{.items[*].metadata.name}');
do
	$OC --request-timeout=20s debug node/${node} -- chroot /host shutdown -h 1
done

echo 
echo "The cluster will complete shutdown and power off in a short while!"
