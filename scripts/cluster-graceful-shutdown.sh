#!/bin/bash
# Attempt a cluster graceful shutdown by terminating all pods on all workers and then shutting down all nodes

source scripts/include_all.sh

aba_debug "Starting: $0 $* in $PWD"

# Honor wait= from aba (e.g. wait=1) or any argv token (robust if order differs).
wait=
for _arg in "$@"; do
	case "$_arg" in
		wait=1|wait=true|wait=yes) wait=1 ;;
	esac
done
[ "$1" = "wait=1" ] && wait=1 && shift

scripts/progress-plan.sh cluster-shutdown
aba_progress "START|sd_preflight"

source <(normalize-aba-conf)
source <(normalize-cluster-conf)

verify-aba-conf || { aba_progress "FAIL|sd_preflight"; aba_progress "ERROR|$_ABA_CONF_ERR"; aba_abort "$_ABA_CONF_ERR"; }
verify-cluster-conf || { aba_progress "FAIL|sd_preflight"; aba_progress "ERROR|Cluster configuration invalid"; exit 1; }

# Resolve kubeconfig (prefer externalized state, fall back to local)
_kc=$(cluster_kubeconfig)
if [ -z "$_kc" ]; then
	aba_progress "FAIL|sd_preflight"
	aba_progress "ERROR|Cannot find kubeconfig"
	aba_progress "NEXT|Expected at ~/.aba/clusters/<name>/kubeconfig or iso-agent-based/auth/kubeconfig"
	aba_abort "Cannot find kubeconfig for this cluster!"
fi
export KUBECONFIG="$_kc"

#aba_info "Ensuring CLI binaries are installed"
scripts/cli-install-all.sh --wait oc

server_url=$(grep " server: " "$KUBECONFIG" | awk '{print $NF}' | head -1)

aba_progress "DONE|sd_preflight"
aba_progress "START|sd_access"

aba_info Checking cluster ...
# Or use: timeout 3 bash -c "</dev/tcp/host/6443"
if ! _curl_err=$(curl --connect-timeout 10 --retry 8 -sSkI $server_url 2>&1 >/dev/null); then
	echo_red "Cluster not reachable at $server_url" >&2
	[ -n "$_curl_err" ] && echo "$_curl_err" >&2
	aba_progress "FAIL|sd_access"
	aba_progress "ERROR|Cluster not reachable at $server_url"
	[ -n "$_curl_err" ] && aba_progress "DETAIL|$_curl_err"
	aba_progress "NEXT|Check that VMs are powered on: aba ls"
	aba_progress "NEXT|Power on VMs with 'aba start' and retry"
	exit 1
fi

aba_info "Attempting to access the cluster ... "

OC="oc --kubeconfig=$KUBECONFIG"

aba_debug "Running: $OC whoami"
if ! _oc_err=$($OC whoami 2>&1 >/dev/null); then
	echo_red "Error: Cannot access the cluster using KUBECONFIG=$KUBECONFIG" >&2
	[ -n "$_oc_err" ] && echo "$_oc_err" >&2
	aba_progress "FAIL|sd_access"
	aba_progress "ERROR|Cannot authenticate to the cluster"
	[ -n "$_oc_err" ] && aba_progress "DETAIL|$_oc_err"
	aba_progress "DETAIL|KUBECONFIG=$KUBECONFIG"
	aba_progress "NEXT|Check if cluster certificates have expired"
	aba_progress "NEXT|Try 'aba login' or check cluster health"
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
# For imported clusters, install-config.yaml/agent-config.yaml don't exist —
# fall back to discovering node IPs from the live cluster API.
if [ -s install-config.yaml ] && [ -s agent-config.yaml ]; then
	eval "$(scripts/cluster-config.sh)" 2>/dev/null || true
fi

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
		aba_warn "Restart the cluster before then to allow automatic CA renewal!"
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
	_enddate="${_enddate#notAfter=}"                    # strip "notAfter=" prefix → date string
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
		aba_warn "Start the cluster before then to allow automatic certificate renewal!"
	fi
fi

if [ "$_showed_cert" = "false" ]; then
	aba_warn "Could not determine certificate expiry. Ensure the cluster is restarted periodically for cert renewal."
fi

aba_info "Never power down a cluster for an extended period without taking a fresh etcd snapshot first!"
echo
ask "Gracefully shut down the cluster" || exit 1

aba_progress "DONE|sd_access"
aba_progress "START|sd_shutdown"

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
	# Red Hat drains every node that has the worker role, including compact
	# control-plane nodes. Dedicated control-plane nodes do not have that label.
	# One node at a time so the API stays up while the others drain. The oc
	# output stays in the log. 60s is the drain limit; --force continues after it.
	# See: https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/backup_and_restore/graceful-shutdown-cluster
	aba_debug "Running: $OC get nodes -l node-role.kubernetes.io/worker (drain loop)"
	for node in $($OC get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[*].metadata.name}');
	do
		aba_info "Draining $node"
		aba_debug "Running: $OC adm drain $node --delete-emptydir-data --ignore-daemonsets=true --timeout=60s --force"
		if ! $OC adm drain ${node} --delete-emptydir-data --ignore-daemonsets=true --timeout=60s --force >> $logfile 2>&1; then
			aba_warn "Drain of $node did not finish. Continuing. See $logfile"
		fi
	done
fi

aba_info "Shutting down all nodes ..." 2>&1 | tee -a $logfile

# Build a map of node name -> IP for SSH.
# Prefer cluster-config.sh data (from install-config/agent-config), fall back
# to querying the live cluster API (needed for imported clusters).
declare -A _node_ip=()
_all_nodes=$($OC get nodes -o jsonpath='{.items[*].metadata.name}')

# The API does not return nodes in agent-config order. Pair each node with
# its own InternalIP. The config list is only a fallback, and it is positional.
while IFS= read -r _pair; do
	[ -n "$_pair" ] || continue
	_n=${_pair%%=*}
	_ip=${_pair#*=}
	[ -n "$_n" ] && [ -n "$_ip" ] && _node_ip[$_n]=$_ip
done < <($OC get nodes -o jsonpath='{range .items[*]}{.metadata.name}={.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' 2>/dev/null || true)

if [ ${#_node_ip[@]} -eq 0 ]; then
	_all_ips="${CP_IP_ADDRESSES:-} ${WKR_IP_ADDR:-}"
	_all_ips=$(echo "$_all_ips" | xargs)
	aba_debug "Node IPs from cluster config: $_all_ips"
	_idx=0
	_ip_arr=($_all_ips)
	for _n in $_all_nodes; do
		if [ $_idx -lt ${#_ip_arr[@]} ]; then
			_node_ip[$_n]="${_ip_arr[$_idx]}"
		fi
		_idx=$(( _idx + 1 ))
	done
fi

aba_debug "Node names: $_all_nodes"

_ssh_available=false
ssh_id_opts=()	# set by cluster_ssh_id_opts
if [ -n "${ssh_key_file:-}" ] && [ ${#_node_ip[@]} -gt 0 ]; then
	# No private key file (only <key>.pub): ssh goes on without -i (ssh-agent and
	# ~/.ssh defaults). A failed SSH falls back to oc debug below. With neither
	# file there is no key for these nodes, so no SSH timeouts are spent.
	cluster_ssh_id_opts "$ssh_key_file" || true
	if [ -f "${ssh_key_file/#\~/$HOME}" ] || [ -f "${ssh_key_file/#\~/$HOME}.pub" ]; then
		_ssh_available=true
	fi
fi

# Hypervisor, so a VM that is already off is not SSH'd or debugged.
_sd_hv=
if [ -s vmware.conf ]; then
	_sd_hv=vmw
	ensure_govc
	source <(normalize-vmware-conf)
elif [ -s kvm.conf ]; then
	_sd_hv=kvm
	ensure_virsh
	source <(normalize-kvm-conf)
fi
[ -n "${CLUSTER_NAME:-}" ] || CLUSTER_NAME=${cluster_name:-}

# Short host name used by vm_name. Prefer the install-config name when the
# API node name is that name or that name plus a domain.
_shutdown_host_short() {
	local node=$1 n short
	short=${node%%.*}
	for n in ${CP_NAMES:-} ${WORKER_NAMES:-}; do
		case "$node" in
			"$n"|"$n".*) short=$n; break ;;
		esac
	done
	printf '%s\n' "$short"
}

# 0 when this node's VM is powered off. 1 when it is on, or when there is
# no hypervisor to ask (bare metal).
_shutdown_vm_is_off() {
	local node=$1 short vm ps state
	[ -n "$_sd_hv" ] || return 1
	[ -n "${CLUSTER_NAME:-}" ] || return 1
	short=$(_shutdown_host_short "$node")
	vm=$(vm_name "$CLUSTER_NAME" "$short")
	if [ "$_sd_hv" = vmw ]; then
		aba_debug "Running: govc vm.info -json $vm"
		ps=$(govc vm.info -json "$vm" 2>>$logfile | jq -r '.virtualMachines[0].runtime.powerState // empty') || return 1
		[ "$ps" = "poweredOff" ]
		return
	fi
	aba_debug "Running: virsh -c $LIBVIRT_URI domstate $vm"
	state=$(virsh -c "${LIBVIRT_URI:-qemu:///system}" domstate "$vm" 2>>$logfile) || return 1
	[ "$state" = "shut off" ]
}

_node_is_ready() {
	local st
	st=$($OC get node "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>>$logfile) || return 1
	[ "$st" = "True" ]
}

# Dedicated workers, then the other control-plane nodes, then the node that
# holds api_vip. Compact masters have the worker role, so they stay with the
# control plane here. The drain above already included them.
_workers=$($OC get nodes -l 'node-role.kubernetes.io/worker,!node-role.kubernetes.io/control-plane,!node-role.kubernetes.io/master' -o jsonpath='{.items[*].metadata.name}' 2>>$logfile) || _workers=
_cps=$($OC get nodes -l 'node-role.kubernetes.io/control-plane' -o jsonpath='{.items[*].metadata.name}' 2>>$logfile) || _cps=
if [ -z "$_cps" ]; then
	_cps=$($OC get nodes -l 'node-role.kubernetes.io/master' -o jsonpath='{.items[*].metadata.name}' 2>>$logfile) || _cps=
fi

_vip_node=
if [ -n "${api_vip:-}" ] && [ "$_ssh_available" = true ]; then
	for node in $_all_nodes; do
		_ip="${_node_ip[$node]:-}"
		[ -n "$_ip" ] || continue
		if timeout 8 ssh -F ~/.aba/ssh.conf "${ssh_id_opts[@]}" -o ConnectTimeout=5 core@"$_ip" "ip -4 -o addr | grep -q ' ${api_vip}/'" >>$logfile 2>&1; then
			_vip_node=$node
			aba_debug "API VIP $api_vip is on $node"
			break
		fi
	done
fi

_ordered=
for node in $_workers $_cps $_all_nodes; do
	[ -n "$node" ] || continue
	[ "$node" = "$_vip_node" ] && continue
	case " $_ordered " in
		*" $node "*) ;;
		*) _ordered="$_ordered $node" ;;
	esac
done
[ -n "$_vip_node" ] && _ordered="$_ordered $_vip_node"
aba_debug "Shutdown order: $_ordered"

_shutdown_failed=
_failed_names=
for node in $_ordered; do
	_ip="${_node_ip[$node]:-}"
	_ok=false

	if _shutdown_vm_is_off "$node"; then
		aba_info "$node${_ip:+ ($_ip)}: already powered off" 2>&1 | tee -a $logfile
		continue
	fi

	# Try SSH first (fast, no image pull needed)
	if [ "$_ssh_available" = "true" ] && [ -n "$_ip" ]; then
		aba_debug "Running: ssh -F ~/.aba/ssh.conf ${ssh_id_opts[*]} core@$_ip 'sudo shutdown -h 1'"
		if timeout 30 ssh -F ~/.aba/ssh.conf "${ssh_id_opts[@]}" core@"$_ip" 'sudo shutdown -h 1' >> $logfile 2>&1; then
			aba_info "$node ($_ip): shutdown via SSH" 2>&1 | tee -a $logfile
			_ok=true
		else
			aba_debug "SSH shutdown failed for $node ($_ip)"
		fi
	fi

	# oc debug only when SSH did not halt the node and the node is still Ready.
	# A NotReady node is the one whose VM is already going down; oc debug hangs there.
	if [ "$_ok" = "false" ] && _node_is_ready "$node"; then
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
		# --kill-after so a debug pod that ignores SIGINT cannot hold the command.
		if timeout --kill-after=10s 60 $OC debug $_debug_image_flag node/${node} -- chroot /host shutdown -h 1 >> $logfile 2>&1; then
			aba_info "$node: shutdown via oc debug" 2>&1 | tee -a $logfile
			_ok=true
		fi
	elif [ "$_ok" = "false" ]; then
		echo "[ABA] $node: not Ready, skipping oc debug" >> $logfile
	fi

	if [ "$_ok" = "false" ]; then
		_shutdown_failed=1
		_failed_names="${_failed_names:+$_failed_names }$node"
		aba_warn "$node${_ip:+ ($_ip)}: shutdown FAILED" 2>&1 | tee -a $logfile
	fi
done

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
# No names to check is "not confirmed", not success.
_shutdown_all_nodes_off() {
	local names name node node_info power_state state
	if [ -s vmware.conf ]; then
		ensure_govc
		source <(normalize-vmware-conf)
		if [ ! "$CLUSTER_NAME" ]; then
			scripts/cluster-config-check.sh || return 1
			eval "$(scripts/cluster-config.sh)" || return 1
		fi
		names=$(echo ${CP_NAMES:-} ${WORKER_NAMES:-})
		[ -n "$names" ] || return 1
		for name in $names; do
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
		names=$(echo ${CP_NAMES:-} ${WORKER_NAMES:-})
		[ -n "$names" ] || return 1
		for name in $names; do
			node=$(vm_name "$CLUSTER_NAME" "$name")
			aba_debug "Running: virsh -c $LIBVIRT_URI domstate $node"
			state=$(virsh -c "$LIBVIRT_URI" domstate "$node" 2>/dev/null)
			[ "$state" = "shut off" ] || return 1
		done
		return 0
	fi
	# Bare-metal or unknown platform — no way to poll power state
	return 1
}

# shutdown -h 1 only schedules the halt. Once that minute has passed, one
# shutdown -h now is sent to any node that still answers SSH. A refused SSH
# is logged and the 40-minute wait continues: sshd stops before the hypervisor
# marks the VM off, so a refused connection is not by itself a failure.
_shutdown_try_halt_now() {
	local node
	[ "$_ssh_available" = true ] || return 0
	aba_info "Trying an immediate halt on nodes that are still on"
	for node in $_ordered; do
		_shutdown_vm_is_off "$node" && continue
		_ip="${_node_ip[$node]:-}"
		[ -n "$_ip" ] || continue
		aba_debug "Running: ssh core@$_ip sudo shutdown -h now"
		if timeout 15 ssh -F ~/.aba/ssh.conf "${ssh_id_opts[@]}" -o ConnectTimeout=8 core@"$_ip" 'sudo shutdown -h now' >>$logfile 2>&1; then
			aba_info "$node ($_ip): shutdown -h now" 2>&1 | tee -a $logfile
		else
			echo "[ABA] $node ($_ip): SSH refused for shutdown -h now" >>$logfile
		fi
	done
}

_shutdown_wait_poll() {
	if _shutdown_all_nodes_off; then
		return 0
	fi
	# The wait helper runs this in a subshell, so a variable set here does not
	# survive the next check. A file does. One immediate halt, not one per poll.
	if [ ! -e "${_halt_now_stamp:-.shutdown.halt-now}" ] && [ "$SECONDS" -ge "${_halt_now_at:-0}" ]; then
		: > "${_halt_now_stamp:-.shutdown.halt-now}"
		_shutdown_try_halt_now
	fi
	return 1
}

# Without --wait this command only triggers the halt. Power-off is confirmed
# only when --wait is set and the platform is VMware or KVM.
aba_progress "DONE|sd_shutdown"
aba_progress "START|sd_poweroff"
if [ "$wait" ] && ! { [ -s vmware.conf ] || [ -s kvm.conf ]; }; then
	aba_info "--wait: bare-metal has no hypervisor to query power state — cannot wait for power-off"
fi
if [ "$wait" ] && { [ -s vmware.conf ] || [ -s kvm.conf ]; }; then
	# Names for the power poll when install-config was not loaded.
	if [ -z "${CP_NAMES:-}${WORKER_NAMES:-}" ]; then
		CP_NAMES=
		for node in $_ordered; do
			CP_NAMES="$CP_NAMES $(_shutdown_host_short "$node")"
		done
	fi
	_wait_mins=40
	_wait_timeout=$(( 60 * _wait_mins ))
	# Func tests shorten the wait and the one-shot halt. Unset, this is 40 minutes
	# and a halt 70s after the scheduled shutdown -h 1.
	if [[ "${ABA_SHUTDOWN_WAIT_SEC:-}" =~ ^[0-9]+$ ]]; then
		_wait_timeout=$ABA_SHUTDOWN_WAIT_SEC
	fi
	_halt_delay=70
	if [[ "${ABA_SHUTDOWN_HALT_NOW_AFTER:-}" =~ ^[0-9]+$ ]]; then
		_halt_delay=$ABA_SHUTDOWN_HALT_NOW_AFTER
	fi
	# The scheduled halt is one minute out. Try shutdown -h now after that.
	_halt_now_at=$(( SECONDS + _halt_delay ))
	_halt_now_stamp=.shutdown.halt-now
	rm -f "$_halt_now_stamp"
	# Log start; do not pipe aba_wait_show to tee — keeps a real TTY so spinner works when interactive.
	echo "[ABA] Waiting up to ${_wait_mins} min for nodes to power off (started $(date -Iseconds))" >> $logfile
	_wait_rc=0
	aba_wait_show "Waiting for nodes to power off (Ctrl-C to abort)" 10 "$_wait_timeout" \
		_shutdown_wait_poll || _wait_rc=$?
	if [ "$_wait_rc" -eq 130 ] || [ "$_wait_rc" -eq 143 ]; then
		echo "" | tee -a $logfile
		aba_info "Aborted. Nodes may still be shutting down in the background."
		aba_progress "FAIL|sd_poweroff"
		exit 130
	elif [ "$_wait_rc" -ne 0 ]; then
		echo "" | tee -a $logfile
		aba ls 2>/dev/null | tee -a $logfile
		aba_progress "FAIL|sd_poweroff"
		aba_progress "ERROR|Timed out waiting for all nodes to power off"
		aba_progress "NEXT|Check VM power state: aba ls"
		aba_progress "NEXT|Power off the VMs that are still on: aba kill"
		aba_abort "Timed out after ${_wait_timeout}s waiting for all nodes to power off. Run 'aba kill' to power off the VMs that are still on."
	else
		echo "" | tee -a $logfile
		echo "[ABA] Node power-off wait finished ($(date -Iseconds))" >> $logfile
		aba_success "All nodes powered off." 2>&1 | tee -a $logfile
		aba_progress "DONE|sd_poweroff"
		exit 0
	fi
fi

if [ -n "$_shutdown_failed" ]; then
	aba_warn "Could not trigger shutdown of: $_failed_names" 2>&1 | tee -a $logfile
	aba_progress "FAIL|sd_poweroff"
	exit 1
fi

aba_success "Triggered shutdown of the cluster nodes. They will power off on their own." 2>&1 | tee -a $logfile
aba_progress "DONE|sd_poweroff"
exit 0
