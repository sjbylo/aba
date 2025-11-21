#!/bin/bash 
# Output the oc cluster login command

[ ! -d iso-agent-based ] && aba_abort "Cluster not installed.  Run 'aba install' to install the cluster or 'aba iso' to create the iso boot image." 

echo "oc login -u kubeadmin -p '$(cat iso-agent-based/auth/kubeadmin-password)' --insecure-skip-tls-verify $(cat iso-agent-based/auth/kubeconfig | grep server | awk '{print $NF}' | head -1)"
