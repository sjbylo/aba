#!/bin/bash
# Start up the cluster.  Need to uncordon to allow pods to run again.

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

[ ! -d iso-agent-based ] && aba_abort "Cluster not installed!  Try running 'aba clean; aba' to install this cluster!"

aba_info "Downloading CLI installation binaries"
scripts/cli-install-all.sh --wait  # FIXME: should only be for oc?

unset KUBECONFIG
# Use the actual kubeconfig used after the cluster was installed, in case it was overwritten
cp iso-agent-based/auth.backup/kubeconfig iso-agent-based/auth/kubeconfig

server_url=$(cat iso-agent-based/auth/kubeconfig | grep " server: " | awk '{print $NF}' | head -1)
cluster_name=$(echo $server_url| grep -o -E '(([a-zA-Z](-?[a-zA-Z0-9])*)\.)+[a-zA-Z]{2,}:[0-9]{2,}' | sed "s/^api\.//g")
server_url=${server_url}/

# Check for bare-metal installation
if [ ! -s vmware.conf ]; then
	echo_yellow "Please power on all bare-metal servers for cluster '$cluster_name'." >&2

	# Quick check to see if servers are up?
	if ! try_cmd -q 1 0 2 curl --connect-timeout 10 --retry 2 -skIL $server_url; then
		# If not, then wait check for longer ...
		aba_info "Waiting for cluster API endpoint to become alive at $server_url ..."

		# Usage: try_cmd [-q] <pause> <interval> <total>
		if ! try_cmd -q 5 0 60 curl --connect-timeout 10 --retry 2 -skIL $server_url; then
			aba_abort "Giving up waiting for the cluster endpoint to become available.  Once the servers start up, please try again!"
		fi
	fi
else
	aba_info Starting cluster $cluster_name ...
	make -s start
fi

# Have quick check if endpoint is available (cluster may already be running)
if ! try_cmd -q 1 0 1 curl --connect-timeout 10 --retry 2 -skIL $server_url; then
	aba_info Waiting for cluster API endpoint to become alive at $server_url ...

	# Now wait for longer...
	if ! try_cmd -q 5 0 60 curl --connect-timeout 10 --retry 2 -skIL $server_url; then
		aba_info "Giving up waiting for the cluster endpoint to become available!"

		exit 1
	fi
fi

OC="oc --kubeconfig $PWD/iso-agent-based/auth/kubeconfig"

# Just to be as sure as possible we can access the cluster!
if ! try_cmd -q 1 0 2 $OC get nodes ; then
	try_cmd -q 3 0 40 $OC get nodes || aba_abort "Giving up waiting!"
fi

echo
aba_info "Cluster endpoint accessible at $server_url"

echo
aba_info Cluster $cluster_name nodes:
echo
if ! $OC get nodes; then
	aba_abort "Failed to access the cluster!"
fi
echo

uncorden_all_nodes() { for node in $($OC get nodes -o jsonpath='{.items[*].metadata.name}'); do $OC adm uncordon ${node}; done; }

sleep 5 	# Sometimes need to wait to avoid uncordon errors!

aba_info "Making all nodes schedulable (uncordon):"
until uncorden_all_nodes
do
	sleep 5
done

# Wait for this command to work!
until $OC get nodes &>/dev/null # >/dev/null 2>&1
do
	sleep 10
done

#all_nodes_ready() { $OC get nodes -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' | grep -v "^True$" || true | wc -l | grep -q "^0$"; }
all_nodes_ready() { [ -z "$($OC get nodes -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' | grep -v ^True$)" ]; }

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
		let i=$i+$pause
		[ $i -gt 3600 ] && exit 0  # Try for ~1 hour
	done
}

(check_and_approve_csrs) &>/dev/null & 
pid=$!
myexit() { [ "$pid" ] && { kill $pid &>/dev/null; sleep 1; kill -9 $pid &>/dev/null; }; exit $1; }
trap myexit EXIT

# Wait for all nodes in Ready state
if ! all_nodes_ready; then
	aba_info "Waiting for all nodes to be 'Ready' ..."

	sleep 8
fi
##$OC get nodes -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}'

echo
aba_info_ok "All nodes are ready!"

echo
$OC get nodes

echo
aba_info "Note the certificate expiration date of this cluster ($cluster_name):"
echo_yellow $($OC -n openshift-kube-apiserver-operator get secret kube-apiserver-to-kubelet-signer -o jsonpath='{.metadata.annotations.auth\.openshift\.io/certificate-not-after}')
echo

console=$($OC whoami --show-console)/
if ! try_cmd -q 1 0 2 "curl -skL $console | grep 'Red Hat OpenShift'"; then
	aba_info_ok "The cluster will complete startup and become fully available shortly!"
	echo
	aba_info "Waiting for the console to become available at $console"

	#check_and_approve_csrs

	if ! try_cmd -q 5 0 60 "curl --retry 2 -skL $console | grep 'Red Hat OpenShift'"; then
		aba_info "Giving up waiting for the console!"
	else
		aba_info_ok "Cluster console is accessible at $console"
	fi
else
	aba_info_ok "Cluster console is accessible at $console"
fi

if ! try_cmd -q 1 0 2 "$OC get co --no-headers | awk '{print \$3,\$5}' | grep -v '^True False\$' | wc -l| grep '^0$'"; then
	aba_info "Waiting for all cluster operators ..."

	if ! try_cmd -q 5 0 60 "$OC get co --no-headers | awk '{print \$3,\$5}' | grep -v '^True False\$' | wc -l| grep '^0$'"; then
		aba_info "Giving up waiting for the operators!"
		myexit 0
	fi
fi

aba_info_ok "All cluster operators are fully available!"

myexit 0

