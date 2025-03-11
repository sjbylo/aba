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

opts=
[ "$DEBUG_ABA" ] && opts="--log-level debug"
echo_yellow "Running: openshift-install agent wait-for install-complete --dir $ASSETS_DIR"
openshift-install agent wait-for install-complete --dir $ASSETS_DIR $opts
ret=$?

if [ $ret -ne 0 ]; then
	echo 
	echo_red "Something went wrong with the installation.  Fix the problem and try again!" >&2

	exit $ret
else
	echo 
	echo_green "The cluster has been successfully installed!"
	echo_green "Run '. <(aba shell)' to access the cluster using the kubeconfig file (x509 cert), or"
	echo_green "Run '. <(aba login)' to log into the cluster using kubeadmin's password."
	[ -f regcreds/pull-secret-mirror.json ] && \
	echo_green "Run 'aba day2' to connect this cluster's OperatorHub to your mirror registry."
	echo_green "Run 'aba day2-ntp' to configure NTP on this cluster."
	echo_green "Run 'aba help' for more options."
fi

