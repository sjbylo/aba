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
echo "openshift-install agent wait-for bootstrap-complete --dir $MANIFEST_DIR"
openshift-install agent wait-for bootstrap-complete --dir $MANIFEST_DIR 

if [ $? -ne 0 ]; then
	echo 
	echo_red "Something went wrong with the installation.  Fix the problem and try again!"

	exit $?
fi

echo
echo =================================================================================
echo Running wait-for command ...
echo "openshift-install agent wait-for install-complete --dir $MANIFEST_DIR"
openshift-install agent wait-for install-complete --dir $MANIFEST_DIR    # --log-level=debug

if [ $? -ne 0 ]; then
	echo 
	echo_red "Something went wrong with the installation.  Fix the problem and try again!"

	exit $?
else
	echo 
	echo_green "The cluster has been successfully installed."
	echo_green "Run '. <(make shell)' to access the cluster using the kubeconfig file (x509 cert), or"
	echo_green "Run '. <(make login)' to log into the cluster using the 'kubeadmin' password. "
	[ -d regcreds ] && echo_green "Run 'make day2' to connect this cluster with your mirror registry."
	echo_green "Run 'make help' for more options."
fi

