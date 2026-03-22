#!/bin/bash
# Attempt a cluster graceful shutdown by terminating all pods on all workers and then shutting down all nodes

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

[ "$1" = "wait=1" ] && wait=1 && shift


[ ! -s iso-agent-based/auth/kubeconfig ] && aba_abort "Cannot find iso-agent-based/auth/kubeconfig file!"

source <(normalize-aba-conf)
source <(normalize-cluster-conf)

verify-aba-conf || aba_abort "$_ABA_CONF_ERR"
verify-cluster-conf || exit 1

aba_info "Ensuring CLI binaries are installed"
scripts/cli-install-all.sh --wait oc

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

# Resolve a debug image from the release payload (available in the mirror via IDMS).
# The default 'oc debug' image (support-tools) lives on registry.redhat.io which is
# unreachable in disconnected environments and has no IDMS redirect.
debug_image=$($OC adm release info --image-for=tools 2>/dev/null || true)
debug_image_flag=
[ "$debug_image" ] && debug_image_flag="--image=$debug_image"

aba_info Cluster $cluster_id nodes:
echo
$OC get nodes
echo

logfile=.shutdown.log
aba_info Start of shutdown $(date) > $logfile

# Load cluster config for SSH fallback (provides CP_IP_ADDRESSES, WKR_IP_ADDR)
eval "$(scripts/cluster-config.sh)" 2>/dev/null || true

# Preparing debug pods for graceful shutdown (pods persist for fast reuse by the actual shutdown call)
declare -A warmup_pids=()
for node in $($OC --request-timeout=30s get nodes -o jsonpath='{.items[*].metadata.name}')
do
	timeout 30 $OC --request-timeout=30s debug $debug_image_flag --preserve-pod node/${node} -- chroot /host hostname &
	warmup_pids[$node]=$!
done >> $logfile 2>&1

if $OC -n openshift-kube-apiserver-operator get secret kube-apiserver-to-kubelet-signer > /dev/null; then
	cluster_exp_date=$($OC -n openshift-kube-apiserver-operator get secret kube-apiserver-to-kubelet-signer -o jsonpath='{.metadata.annotations.auth\.openshift\.io/certificate-not-after}')

	# Convert the target date to a format compatible with date command
	cluster_exp_date_seconds=$(date -d "$cluster_exp_date" +%s)

	# Get the current date in seconds since epoch
	current_date_seconds=$(date +%s)

	# Calculate the difference in seconds and then convert to days
	seconds_diff=$((cluster_exp_date_seconds - current_date_seconds))
	days_diff=$((seconds_diff / 86400))

	### FIXME: aba_info "Certificate expiration date of cluster: $cluster_id: $cluster_exp_date"
	### FIXME: echo_yellow "[ABA] The cluster certificate will expire in $days_diff days."  # FIXME: This needs to be corrected!
	### FIXME: aba_info "Start the cluster beforehand to ensure the cluster's CA certificate renews automatically."

else
	echo_red "Unable to discover cluster's certificate expiration date." >&2
fi

echo
ask "Gracefully shut down the cluster" || exit 1

# Wait for all warmup debug pods; abort if any fail (e.g. image pull issue in disconnected env)
warmup_failed=
for node in "${!warmup_pids[@]}"; do
	if ! wait ${warmup_pids[$node]}; then
		warmup_failed=1
		aba_warning "Debug pod warmup failed for node $node" | tee -a $logfile
	fi
done

if [ "$warmup_failed" ]; then
	aba_abort "Debug pod warmup failed (image pull for 'oc debug' likely failed)." \
		"Ensure 'aba day2' has been run to configure image mirroring (IDMS/ITMS)" \
		"and that the mirror registry is accessible from the cluster nodes."
fi

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

oc_debug_failed=
nodes=$($OC get nodes -o jsonpath='{.items[*].metadata.name}')

for node in $nodes; do
	if ! timeout 30 $OC debug $debug_image_flag node/${node} -- chroot /host shutdown -h 1 >> $logfile 2>&1; then
		oc_debug_failed=1
		aba_warning "oc debug shutdown failed for $node" | tee -a $logfile
	fi
done

if [ "$oc_debug_failed" ]; then
	aba_warning "Falling back to SSH for shutdown ..." | tee -a $logfile
	for ip in $CP_IP_ADDRESSES $WKR_IP_ADDR; do
		timeout 30 ssh -F ~/.aba/ssh.conf -i $ssh_key_file core@$ip 'sudo shutdown -h 1' >> $logfile 2>&1 || \
			aba_warning "SSH shutdown also failed for $ip" | tee -a $logfile
	done
fi

echo
aba_info_ok "All servers in the cluster will complete shutdown and power off shortly!" | tee -a $logfile

# Clean up stale debug pods that could re-execute shutdown on next boot.
# The 'oc debug ... shutdown -h now' pods persist in etcd; if the kubelet
# re-syncs them on startup the node enters an infinite shutdown loop.
for pod in $($OC get pods -n default --no-headers 2>/dev/null | grep "\-debug-" | awk '{print $1}'); do
	$OC delete pod -n default "$pod" --grace-period=0 --force >> $logfile 2>&1 || true
done

# Only wait if installed on VMs (VMware or KVM)
if [ "$wait" ] && { [ -s vmware.conf ] || [ -s kvm.conf ]; }; then
	aba_info "Waiting for all nodes to power down ..." | tee -a $logfile
	until ! aba ls 2>/dev/null | grep -qiE 'poweredOn|running'; do sleep 10; done
fi

exit 0
