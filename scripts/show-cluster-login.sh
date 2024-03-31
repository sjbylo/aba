#!/bin/bash 

echo "oc login -u kubeadmin -p '$(cat iso-agent-based/auth/kubeadmin-password)' $(cat iso-agent-based/auth/kubeconfig | grep server | awk '{print $NF}')"
