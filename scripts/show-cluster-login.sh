#!/bin/bash 
# Output the oc cluster login command

source scripts/include_all.sh

[ ! -d iso-agent-based ] && aba_abort "Cluster not installed.  Run 'aba install' to install the cluster or 'aba iso' to create the iso boot image."

# Ensure oc is available (only wait for oc, not all CLIs)
ensure_oc >&2

echo "oc login -u kubeadmin -p '$(cat iso-agent-based/auth/kubeadmin-password)' --insecure-skip-tls-verify $(cat iso-agent-based/auth/kubeconfig | grep server | awk '{print $NF}' | head -1)"
