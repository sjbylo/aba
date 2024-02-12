#!/bin/bash -e

export KUBECONFIG=$PWD/aba/sno/iso-agent-based/auth/kubeconfig

cd ~/aba/test/mesh/openshift-service-mesh-demo

sed -i "s/quay\.io/$reg_host:$reg_port/g" */*.yaml */*/*.yaml */*/*/*.yaml

echo "y" | ./00-install-all.sh

