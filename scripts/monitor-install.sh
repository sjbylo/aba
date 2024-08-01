#!/bin/bash 
# This will run the 'wait-for' command and output next steps after ocp installation

source scripts/include_all.sh

[ "$1" ] && set -x 

if [ ! "$CLUSTER_NAME" ]; then
	scripts/cluster-config-check.sh
	eval $(scripts/cluster-config.sh $@ || exit 1)
fi

echo 
echo =================================================================================
echo Running wait-for command ...
echo "openshift-install agent wait-for bootstrap-complete --dir $MANEFEST_DIR"
openshift-install agent wait-for bootstrap-complete --dir $MANEFEST_DIR 

if [ $? -ne 0 ]; then
	echo 
	echo "Something went wrong with the installation.  Fix the problem and try again!"

	exit $?
fi

echo
echo =================================================================================
echo Running wait-for command ...
echo "openshift-install agent wait-for install-complete --dir $MANEFEST_DIR"
openshift-install agent wait-for install-complete --dir $MANEFEST_DIR    # --log-level=debug

if [ $? -ne 0 ]; then
	echo 
	echo "Something went wrong with the installation.  Fix the problem and try again!"

	exit $?
else
	echo 
	echo "The cluster has been successfully installed."
	echo "Run '. <(make shell)' to access the cluster using the kubeconfig file (x509 cert), or"
	echo "Run '. <(make login)' to log into the cluster using the 'kubeadmin' password. "
fi

