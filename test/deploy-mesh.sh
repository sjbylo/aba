#!/bin/bash -e
# This test script is run on the remote internal bastion only

export KUBECONFIG=$PWD/aba/sno/iso-agent-based/auth/kubeconfig

cd ~/aba/test/mesh/openshift-service-mesh-demo

# Use this simple method.   The "redirect methods" are problematic.
sed -i "s/quay\.io/$reg_host:$reg_port/g" */*.yaml */*/*.yaml */*/*/*.yaml

echo "y" | ./00-install-all.sh

