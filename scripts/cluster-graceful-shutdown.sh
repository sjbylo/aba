#!/bin/bash
# Attempt a cluster graceful shutdown by terminating all pods on all workers and then shutting down all nodes

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

# Honor wait= from aba (e.g. wait=1) or any argv token (robust if order differs).
wait=
for _arg in "$@"; do
	case "$_arg" in
		wait=1|wait=true|wait=yes) wait=1 ;;
	esac
done
[ "$1" = "wait=1" ] && wait=1 && shift

[ ! -s iso-agent-based/auth/kubeconfig ] && aba_abort "Cannot find iso-agent-based/auth/kubeconfig file!"

source <(normalize-aba-conf)
source <(normalize-cluster-conf)

verify-aba-conf || aba_abort "$_ABA_CONF_ERR"
verify-cluster-conf || exit 1

#aba_info "Ensuring CLI binaries are installed"
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

aba_debug "Running: $OC whoami"
if ! $OC whoami >/dev/null; then
	echo_red "Error: Cannot access the cluster using iso-agent-based/auth/kubeconfig file!" >&2

	exit 1
fi

aba_debug "Running: $OC whoami --show-server"
cluster_id=$($OC whoami --show-server | awk -F[/:] '{print $4}') || exit 1

aba_info Cluster $cluster_id nodes:
echo
exec_cmd="$OC get nodes"
aba_debug "Running: $exec_cmd"
$exec_cmd
echo

logfile=.shutdown.log
aba_info Start of shutdown $(date) > $logfile

# Load cluster config (provides CP_IP_ADDRESSES, WKR_IP_ADDR, ssh_key_file)
eval "$(scripts/cluster-config.sh)" 2>/dev/null || true

# --- Certificate expiry warnings ---
# Show the soonest-expiring cert so the user knows the safe shutdown window.
_now=$(date +%s)
_cert_warning_days=90
_showed_cert=false

# 1) Cluster CA: kube-apiserver-to-kubelet-signer
aba_debug "Running: $OC -n openshift-kube-apiserver-operator get secret kube-apiserver-to-kubelet-signer"
if _ca_date=$($OC -n openshift-kube-apiserver-operator get secret kube-apiserver-to-kubelet-signer \
	-o jsonpath='{.metadata.annotations.auth\.openshift\.io/certificate-not-after}' 2>/dev/null) && [ -n "$_ca_date" ]; then
	_ca_secs=$(date -d "$_ca_date" +%s 2>/dev/null) || _ca_secs=0
	_ca_days=$(( (_ca_secs - _now) / 86400 ))
	_ca_short=$(date -d "$_ca_date" +%Y-%m-%d 2>/dev/null || echo "$_ca_date")
	aba_info "Cluster CA certificate expires in ${_ca_days} days ($_ca_short)"
	_showed_cert=true
	if [ "$_ca_days" -lt "$_cert_warning_days" ]; then
		aba_warning "Restart the cluster before then to allow automatic CA renewal!"
	fi
fi

# 2) Nearest node/kubelet certificate: scan TLS secrets for the soonest expiry
aba_debug "Scanning kubelet-related TLS secrets for nearest expiry ..."
_nearest_days=999999
_nearest_date=""
while IFS=$'\t' read -r _ns _name _b64cert; do
	[ -z "$_b64cert" ] && continue
	_enddate=$(echo "$_b64cert" | base64 -d 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null) || continue
	# _enddate is like "notAfter=Oct  3 12:00:00 2026 GMT"
	_enddate="${_enddate#notAfter=}"
	_end_secs=$(date -d "$_enddate" +%s 2>/dev/null) || continue
	_days=$(( (_end_secs - _now) / 86400 ))
	if [ "$_days" -lt "$_nearest_days" ]; then
		_nearest_days=$_days
		_nearest_date=$(date -d "$_enddate" +%Y-%m-%d 2>/dev/null || echo "$_enddate")
		_nearest_name="$_ns/$_name"
	fi
done < <($OC get secrets -A \
	-o go-template='{{range .items}}{{if eq .type "kubernetes.io/tls"}}{{.metadata.namespace}}	{{.metadata.name}}	{{index .data "tls.crt"}}{{"\n"}}{{end}}{{end}}' 2>/dev/null \
	| grep -i "kubelet\|kube-apiserver-to-kubelet\|serving-cert")

if [ "$_nearest_days" -lt 999999 ]; then
	aba_info "Nearest node certificate expires in ${_nearest_days} days ($_nearest_date)"
	_showed_cert=true
	if [ "$_nearest_days" -lt "$_cert_warning_days" ]; then
		aba_warning "Start the cluster before then to allow automatic certificate renewal!"
	fi
fi

if [ "$_showed_cert" = "false" ]; then
	aba_warning "Could not determine certificate expiry. Ensure the cluster is restarted periodically for cert renewal."
fi

aba_info "Never power down a cluster for an extended period without taking a fresh etcd snapshot first!"
echo
ask "Gracefully shut down the cluster" || exit 1

aba_info "Cluster ready for graceful shutdown! Logging full output to $logfile ..." 2>&1 | tee -a $logfile

# If not SNO ...
if [ $num_masters -ne 1 -o $num_workers -ne 0 ]; then
	aba_info "Making all nodes unschedulable (cordon) ..." 2>&1 | tee -a $logfile
	for node in $($OC get nodes -o jsonpath='{.items[*].metadata.name}')
	do
		aba_debug "Running: $OC adm cordon $node"
		$OC adm cordon ${node} 2>> $logfile &
	done | tee -a $logfile
	wait

	aba_info "Draining all pods from all worker nodes ..." 2>&1 | tee -a $logfile
	sleep 1
	aba_debug "Running: $OC get nodes -l node-role.kubernetes.io/worker (drain loop)"
	for node in $($OC get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[*].metadata.name}'); 
	do
		aba_info Drain ${node}
		aba_debug "Running: $OC adm drain $node --delete-emptydir-data --ignore-daemonsets=true --timeout=60s --force"
		$OC adm drain ${node} --delete-emptydir-data --ignore-daemonsets=true --timeout=60s --force &
		# See: https://docs.redhat.com/en/documentation/openshift_container_platform/4.16/html-single/backup_and_restore/index#graceful-shutdown_graceful-shutdown-cluster
	done >> $logfile 2>&1

	wait
fi

aba_info "Shutting down all nodes ..." 2>&1 | tee -a $logfile

# Build a map of node name -> IP for SSH (node names and IPs come from cluster-config.sh)
declare -A _node_ip=()
_all_ips="$CP_IP_ADDRESSES $WKR_IP_ADDR"
_all_nodes=$($OC get nodes -o jsonpath='{.items[*].metadata.name}')
aba_debug "Node names: $_all_nodes"
aba_debug "Node IPs: $_all_ips"

# Pair each node name with its IP (same order from cluster-config.sh)
_idx=0
_ip_arr=($_all_ips)
for _n in $_all_nodes; do
	if [ $_idx -lt ${#_ip_arr[@]} ]; then
		_node_ip[$_n]="${_ip_arr[$_idx]}"
	fi
	_idx=$(( _idx + 1 ))
done

_ssh_available=false
if [ -n "${ssh_key_file:-}" ] && [ -f "${ssh_key_file/#\~/$HOME}" ] && [ ${#_node_ip[@]} -gt 0 ]; then
	_ssh_available=true
	_ssh_key="${ssh_key_file/#\~/$HOME}"
fi

_shutdown_failed=
for node in $_all_nodes; do
	_ip="${_node_ip[$node]:-}"
	_ok=false

	# Try SSH first (fast, no image pull needed)
	if [ "$_ssh_available" = "true" ] && [ -n "$_ip" ]; then
		aba_debug "Running: ssh -F ~/.aba/ssh.conf -i $_ssh_key core@$_ip 'sudo shutdown -h 1'"
		if timeout 30 ssh -F ~/.aba/ssh.conf -i "$_ssh_key" core@"$_ip" 'sudo shutdown -h 1' >> $logfile 2>&1; then
			aba_info "$node ($_ip): shutdown via SSH" 2>&1 | tee -a $logfile
			_ok=true
		else
			aba_debug "SSH shutdown failed for $node ($_ip), trying oc debug fallback"
		fi
	fi

	# Fall back to oc debug if SSH unavailable or failed
	if [ "$_ok" = "false" ]; then
		# Resolve debug image on first use (lazy — only when oc debug is actually needed)
		if [ -z "${_debug_image_flag+x}" ]; then
			aba_debug "Running: $OC adm release info --image-for=tools"
			_debug_image=$($OC adm release info --image-for=tools 2>/dev/null || true)
			_debug_image_flag=
			if [ -n "$_debug_image" ]; then
				_debug_image_flag="--image=$_debug_image"
			fi
		fi

		aba_debug "Running: $OC debug $_debug_image_flag node/$node -- chroot /host shutdown -h 1"
		if timeout 60 $OC debug $_debug_image_flag node/${node} -- chroot /host shutdown -h 1 >> $logfile 2>&1; then
			aba_info "$node: shutdown via oc debug" 2>&1 | tee -a $logfile
			_ok=true
		fi
	fi

	if [ "$_ok" = "false" ]; then
		_shutdown_failed=1
		aba_warning "$node${_ip:+ ($_ip)}: shutdown FAILED (SSH and oc debug both failed)" 2>&1 | tee -a $logfile
	fi
done

echo
if [ -z "$_shutdown_failed" ]; then
	aba_info_ok "All nodes will complete shutdown and power off shortly!" 2>&1 | tee -a $logfile
else
	aba_warning "Some nodes could not be reached — check $logfile for details" 2>&1 | tee -a $logfile
fi

# Clean up stale debug pods that could re-execute shutdown on next boot.
# 'oc debug ... shutdown' pods persist in etcd; if kubelet re-syncs them
# on startup the node enters an infinite shutdown loop.
aba_debug "Running: $OC get pods -n default (cleanup stale debug pods)"
for pod in $($OC get pods -n default --no-headers 2>/dev/null | grep "\-debug-" | awk '{print $1}'); do
	aba_debug "Running: $OC delete pod -n default $pod --grace-period=0 --force"
	$OC delete pod -n default "$pod" --grace-period=0 --force >> $logfile 2>&1 || true
done

# True when every node for this cluster is powered off (VMware: poweredOff only; KVM: shut off).
# Do not use "aba ls | grep" alone — empty output or non-off states (e.g. suspended) must not pass.
_shutdown_all_nodes_off() {
	if [ -s vmware.conf ]; then
		ensure_govc
		source <(normalize-vmware-conf)
		if [ ! "$CLUSTER_NAME" ]; then
			scripts/cluster-config-check.sh || return 1
			eval "$(scripts/cluster-config.sh)" || return 1
		fi
		local name node_info power_state
		for name in $CP_NAMES $WORKER_NAMES; do
			node=$(vm_name "$CLUSTER_NAME" "$name")
			aba_debug "Running: govc vm.info -json $node"
			node_info=$(govc vm.info -json "$node")
			[ ! "$node_info" ] && return 1
			power_state=$(echo "$node_info" | jq -r '.virtualMachines[0].runtime.powerState')
			[ "$power_state" = "null" ] && return 1
			[ "$power_state" = "poweredOff" ] || return 1
		done
		return 0
	fi
	if [ -s kvm.conf ]; then
		ensure_virsh
		source <(normalize-kvm-conf)
		if [ ! "$CLUSTER_NAME" ]; then
			scripts/cluster-config-check.sh || return 1
			eval "$(scripts/cluster-config.sh)" || return 1
		fi
		local name state
		for name in $CP_NAMES $WORKER_NAMES; do
			node=$(vm_name "$CLUSTER_NAME" "$name")
			aba_debug "Running: virsh -c $LIBVIRT_URI domstate $node"
			state=$(virsh -c "$LIBVIRT_URI" domstate "$node" 2>/dev/null)
			[ "$state" = "shut off" ] || return 1
		done
		return 0
	fi
	# Bare-metal or unknown platform — no way to poll power state; assume shutdown succeeded
	return 0
}

# Only wait for power-off if platform supports it (VMware or KVM)
if [ "$wait" ] && { [ -s vmware.conf ] || [ -s kvm.conf ]; }; then
	_wait_mins=40
	_wait_timeout=$(( 60 * _wait_mins ))
	# Log start; do not pipe aba_wait_show to tee — keeps a real TTY so spinner works when interactive.
	echo "[ABA] Waiting up to ${_wait_mins} min for nodes to power off (started $(date -Iseconds))" >> $logfile
	_wait_rc=0
	aba_wait_show "Waiting for nodes to power off (Ctrl-C to abort)" 10 "$_wait_timeout" \
		_shutdown_all_nodes_off || _wait_rc=$?
	if [ "$_wait_rc" -eq 130 ] || [ "$_wait_rc" -eq 143 ]; then
		echo "" | tee -a $logfile
		aba_info "Aborted. Nodes may still be shutting down in the background."
	elif [ "$_wait_rc" -ne 0 ]; then
		echo "" | tee -a $logfile
		aba ls 2>/dev/null | tee -a $logfile
		aba_abort "Timed out after ${_wait_timeout}s waiting for all nodes to power off"
	else
		echo "" | tee -a $logfile
		echo "[ABA] Node power-off wait finished ($(date -Iseconds))" >> $logfile
		aba_info_ok "All nodes powered off." 2>&1 | tee -a $logfile
	fi
fi

exit 0
