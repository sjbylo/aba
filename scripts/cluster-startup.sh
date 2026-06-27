#!/bin/bash
# Start up the cluster.  Need to uncordon to allow pods to run again.

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

source <(normalize-cluster-conf)

# Resolve kubeconfig (prefer externalized state under ~/.aba/, fall back to local)
_kc=$(cluster_kubeconfig)
if [ -z "$_kc" ]; then
	aba_abort "Cluster not installed! Cannot find kubeconfig. Try running 'aba clean; aba' to install this cluster!"
fi
export KUBECONFIG="$_kc"

#aba_info "Ensuring CLI binaries are installed"
scripts/cli-install-all.sh --wait oc

server_url=$(grep " server: " "$KUBECONFIG" | awk '{print $NF}' | head -1)
cluster_name=$(echo $server_url| grep -o -E '(([a-zA-Z](-?[a-zA-Z0-9])*)\.)+[a-zA-Z]{2,}:[0-9]{2,}' | sed "s/^api\.//g")
server_url=${server_url}/

_cluster_startup_api_up() {
	curl --connect-timeout 10 --retry 2 -skIL "$server_url" >/dev/null
}

# Check for bare-metal installation (no hypervisor config)
if [ ! -s vmware.conf ] && [ ! -s kvm.conf ]; then
	echo_yellow "Please power on all bare-metal servers for cluster '$cluster_name'." >&2

	# Quick check to see if servers are up?
	if ! curl --connect-timeout 10 --retry 2 -skIL "$server_url" >/dev/null; then
		aba_info "Waiting for cluster API endpoint to become alive at $server_url ..."
		_wait_rc=0
		aba_wait_show "Waiting for cluster API (Ctrl-C to abort)" 5 300 _cluster_startup_api_up || _wait_rc=$?
		if [ "$_wait_rc" -eq 130 ] || [ "$_wait_rc" -eq 143 ]; then
			aba_info "Aborted. Power on the servers and try again."
			exit 0
		elif [ "$_wait_rc" -ne 0 ]; then
			aba_abort "Cluster API not available at $server_url after 5 min. Power on all servers and try again."
		fi
	fi
else
	aba_info Starting cluster $cluster_name ...
	aba start
fi

# Have quick check if endpoint is available (cluster may already be running)
if ! curl --connect-timeout 10 --retry 2 -skIL "$server_url" >/dev/null; then
	aba_info Waiting for cluster API endpoint to become alive at $server_url ...
	_wait_rc=0
	aba_wait_show "Waiting for cluster API (Ctrl-C to abort)" 5 300 _cluster_startup_api_up || _wait_rc=$?
	if [ "$_wait_rc" -eq 130 ] || [ "$_wait_rc" -eq 143 ]; then
		aba_info "Aborted. Cluster may still be starting up."
		exit 0
	elif [ "$_wait_rc" -ne 0 ]; then
		aba_abort "Cluster API not available at $server_url after 5 min." \
			"Check that VMs are powered on ('aba ls') and the cluster is healthy."
	fi
fi

OC="oc --kubeconfig $KUBECONFIG"

_cluster_startup_oc_get_nodes() {
	exec_cmd="$OC get nodes"
	aba_debug "Running: $exec_cmd"
	$exec_cmd
}

# Just to be as sure as possible we can access the cluster!
aba_debug "Running: $OC get nodes"
if ! $OC get nodes; then
	if ! aba_wait_show "Waiting for oc get nodes" 3 120 _cluster_startup_oc_get_nodes; then
		aba_abort "Cluster API not responding after 2 min. Check 'aba ls' and cluster health."
	fi
fi

aba_info "Cluster endpoint accessible at $server_url"
rm -f .shutdown.log

# Remove stale 'oc debug' pods that may re-execute shutdown commands.
# These persist in etcd after a graceful shutdown and can cause an
# infinite shutdown loop when kubelet re-syncs them on startup.
aba_debug "Running: $OC get pods -n default (checking for stale debug pods)"
for pod in $($OC get pods -n default --no-headers 2>/dev/null | grep "\-debug-" | awk '{print $1}'); do
	aba_info "Removing stale debug pod: $pod"
	aba_debug "Running: $OC delete pod -n default $pod --grace-period=0 --force"
	$OC delete pod -n default "$pod" --grace-period=0 --force 2>/dev/null || true
done

aba_info Cluster $cluster_name nodes:
aba_debug "Running: $OC get nodes"
if ! $OC get nodes; then
	aba_abort "Failed to access the cluster!"
fi

uncordon_all_nodes() { for node in $($OC get nodes -o jsonpath='{.items[*].metadata.name}'); do $OC adm uncordon ${node}; done; }

sleep 5 	# Sometimes need to wait to avoid uncordon errors!

aba_info "Making all nodes schedulable (uncordon):"
if ! aba_wait_show "Uncordon all nodes" 5 600 uncordon_all_nodes; then
	aba_warning "Uncordon did not fully complete after 10 minutes, continuing ..."
fi

# Wait for this command to work!
if ! aba_wait_show "Waiting for cluster API after uncordon" 10 300 _cluster_startup_oc_get_nodes; then
	aba_warning "Could not reach cluster API after 5 minutes, continuing ..."
fi

all_nodes_ready() { aba_debug "Running: $OC get nodes (all_nodes_ready check)"; [ -z "$($OC get nodes -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' | grep -v ^True$)" ]; }

check_and_approve_csrs() {
	# Keep on watching for and approving those CSRs ...
	local i=0
	local pause=5
	while true
	do
		# Check any pending CSRs
		CSRS=$($OC get csr -A --no-headers 2>/dev/null | grep -i pending | awk '{print $1}')
		if [ "$CSRS" ]; then
			aba_info "$OC adm certificate approve $CSRS"
			$OC adm certificate approve $CSRS
		fi

		sleep $pause
		i=$(( i + pause ))
		[ $i -gt 3600 ] && exit 0  # Try for ~1 hour
	done
}

(check_and_approve_csrs) &>/dev/null & 
pid=$!
trap '_rc=$?; trap - ERR; kill $pid &>/dev/null; wait $pid 2>/dev/null; exit $_rc' EXIT

# Wait for all nodes in Ready state
if ! all_nodes_ready; then
	if ! aba_wait_show "Waiting for all nodes Ready (Ctrl-C to skip)" 10 600 all_nodes_ready; then
		aba_warning "Not all nodes are 'Ready' yet, but continuing ..."
	fi
fi

if all_nodes_ready; then
	aba_info_ok "All nodes are ready!"
fi
exec_cmd="$OC get nodes"
aba_debug "Running: $exec_cmd"
$exec_cmd
aba_info "Note the certificate expiration date of this cluster ($cluster_name):"
aba_debug "Running: $OC -n openshift-kube-apiserver-operator get secret kube-apiserver-to-kubelet-signer"
echo_yellow $($OC -n openshift-kube-apiserver-operator get secret kube-apiserver-to-kubelet-signer -o jsonpath='{.metadata.annotations.auth\.openshift\.io/certificate-not-after}')

aba_debug "Running: $OC whoami --show-console"
console=$($OC whoami --show-console)/

_cluster_startup_console_ready() {
	aba_debug "Running: curl -skL $console (console ready check)"
	curl --retry 2 -skL "$console" | grep -q 'Red Hat OpenShift'
}

_cluster_startup_cos_ready() {
	aba_debug "Running: $OC get co --no-headers (cluster operators ready check)"
	$OC get co --no-headers | awk '{print $3,$5}' | grep -v '^True False$' | wc -l | grep -q '^0$'
}

_console_ok=""
if ! curl -skL "$console" | grep -q 'Red Hat OpenShift'; then
	aba_info_ok "The cluster will complete startup and become fully available shortly!"
	aba_info "Waiting for the console to become available at $console"
	if ! aba_wait_show "Waiting for OpenShift console (Ctrl-C to skip)" 5 300 _cluster_startup_console_ready; then
		aba_info "Console not ready yet, continuing ..."
	else
		aba_info_ok "Cluster console is accessible at $console"
		_console_ok=1
	fi
else
	aba_info_ok "Cluster console is accessible at $console"
	_console_ok=1
fi

if ! _cluster_startup_cos_ready; then
	aba_info "Waiting for all cluster operators ..."
	if ! aba_wait_show "Waiting for all cluster operators (Ctrl-C to skip)" 5 300 _cluster_startup_cos_ready; then
		aba_info "Not all cluster operators are available yet. The cluster may still be settling."
		exit 0
	fi
fi

aba_info_ok "All cluster operators are fully available!"

# Re-check console if it wasn't ready earlier (may have come up during operator wait)
if [ -z "$_console_ok" ]; then
	if _cluster_startup_console_ready 2>/dev/null; then
		aba_info_ok "Cluster console is accessible at $console"
	else
		aba_info "Console not accessible yet at $console -- it should appear shortly."
	fi
fi

exit 0

