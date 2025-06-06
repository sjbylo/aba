#!/bin/bash 
# This will run the 'wait-for' command and output next steps after ocp installation

source scripts/include_all.sh
trap - ERR  # We don't want to catch on error. error handling added below. 

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
[ "$ABA_DEBUG" ] && echo openshift-install returned: $ret >&2

# All exit codes of openshift-install from source file: cmd/openshift-install/create.go
# Declare an associative array with exit codes as keys
declare -A wait_for_exit_reasons=(
    [3]="Installation configuration error"
    [4]="Infrastructure failed"
    [5]="Bootstrap failed"
    [6]="Install failed"
    [7]="Operator stability failed"
    [8]="Interrupted"
)

if [ $ret -ne 0 ]; then
	# ret = 8 means openshift-install was interrupted (e.g. Ctrl-c), for that we don't want to show any errors. 
	if [ $ret -ne 8 ]; then
		echo 
		echo_red "Something went wrong with the installation.  Fix the problem and try again!" >&2
		[ "${wait_for_exit_reasons[$ret]}" ] && echo_yellow "Reason: '${wait_for_exit_reasons[$ret]} ($ret)'" || echo_yellow "Reason: 'Unknown ($ret)'"

		exit $ret
	fi
else
	echo 
	echo_green "The cluster has been successfully installed!"
	echo_green "Run '. <(aba shell)' to access the cluster using the kubeconfig file (client cert), or"
	echo_green "Run '. <(aba login)' to log into the cluster using kubeadmin's password."
	[ -f regcreds/pull-secret-mirror.json ] && \
		echo_green "Run 'aba day2' to connect this cluster's OperatorHub to your mirror registry (run after adding any operators to your mirror)." && \
		echo_green "Run 'aba day2-osus' to configure the OpenShift Update Service."
	echo_green "Run 'aba day2-ntp' to configure NTP on this cluster."
	echo_green "Run 'aba info' to view this information again."
	echo_green "Run 'aba help' and 'aba -h' for more options."
fi

