#!/bin/bash 

[ ! -d iso-agent-based ] && echo "Cluster not installed.  Run 'make' to install the cluster or 'make iso' to create the iso boot image." && exit 1

echo "oc login -u kubeadmin -p '$(cat iso-agent-based/auth/kubeadmin-password)' --insecure-skip-tls-verify $(cat iso-agent-based/auth/kubeconfig | grep server | awk '{print $NF}' | head -1)"
