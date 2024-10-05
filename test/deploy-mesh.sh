#!/bin/bash -ex
# This test script is run on the remote internal bastion only

cd $(dirname $0)
cd ..
pwd

. <(cd sno; make shell)

cd test/mesh/openshift-service-mesh-demo

if ! echo "y" | ./00-install-all.sh; then
	echo y| ./99-uninstall-all.sh
	echo "y" | ./00-install-all.sh
fi

