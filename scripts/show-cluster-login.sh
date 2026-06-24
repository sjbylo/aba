#!/bin/bash 
# Output the oc cluster login command

source scripts/include_all.sh

source <(normalize-cluster-conf)

# Resolve kubeconfig (prefer externalized state, fall back to local)
_kc=$(cluster_kubeconfig)
[ -z "$_kc" ] && aba_abort "Cluster not installed. Run 'aba install' to install the cluster or 'aba iso' to create the iso boot image."

# Resolve kubeadmin password (externalized or local)
_sd=$(cluster_state_dir 2>/dev/null) || _sd=""
if [ -n "$_sd" ] && [ -f "$_sd/kubeadmin-password" ]; then
	_pw=$(cat "$_sd/kubeadmin-password")
else
	_pw=$(cat iso-agent-based/auth/kubeadmin-password 2>/dev/null)
fi

# Ensure oc is available (only wait for oc, not all CLIs)
ensure_oc >&2

echo "oc login -u kubeadmin -p '$_pw' --insecure-skip-tls-verify $(grep server "$_kc" | awk '{print $NF}' | head -1)"
