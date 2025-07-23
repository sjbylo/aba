#!/bin/bash -ex
# This test script is run on the remote internal bastion only

cd $(dirname $0)
cd ..
pwd

#. <(cd sno; aba -s shell)
. <(aba --dir sno shell)

cd test/mesh/openshift-service-mesh-demo

if ! echo "y" | ./00-install-all-mesh3.sh; then
	echo y| ./99-uninstall-all-mesh3.sh
	#echo "y" | ./00-install-all.sh
fi

