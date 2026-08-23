#!/bin/bash -e
# This script displays the access credentials for an installed cluster

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

source <(normalize-aba-conf)
source <(normalize-cluster-conf)
export regcreds_dir=$HOME/.aba/mirror/$(image_source_mirror_name)
verify-aba-conf || aba_abort "$_ABA_CONF_ERR"
verify-cluster-conf || exit 1

# Resolve kubeconfig (prefers local, falls back to externalized state)
kc=$(cluster_kubeconfig)
[ -z "$kc" ] && aba_abort "Cluster not ready! Cannot find kubeconfig."

# Resolve kubeadmin password (prefer local, fall back to externalized state)
if [ -f "iso-agent-based/auth/kubeadmin-password" ]; then
	pw=$(cat "iso-agent-based/auth/kubeadmin-password")
else
	_sd=$(cluster_state_dir 2>/dev/null) || _sd=""
	if [ -n "$_sd" ] && [ -f "$_sd/kubeadmin-password" ]; then
		pw=$(cat "$_sd/kubeadmin-password")
	fi
fi

aba_info "To access the cluster as the system:admin user when using 'oc', run"
aba_info "    export KUBECONFIG=$kc"
aba_info "Access the OpenShift web-console here: https://console-openshift-console.apps.$cluster_name.$base_domain"
aba_info "Login to the console with user: \"kubeadmin\", and password: \"$pw\""

show_cluster_summary


