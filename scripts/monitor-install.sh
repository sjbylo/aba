#!/bin/bash 
# This will run the 'wait-for' command and output next steps after ocp installation

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

trap - ERR  # We don't want to catch on error. error handling added below. 

 

if [ ! "$CLUSTER_NAME" ]; then
	scripts/cluster-config-check.sh
	eval $(scripts/cluster-config.sh $@ || exit 1)
fi

echo
echo "[ABA] ================================================================================="

opts=
[ "$DEBUG_ABA" ] && opts="--log-level debug"

echo_yellow "[ABA] Running: openshift-install agent wait-for install-complete --dir $ASSETS_DIR"

#sleep 60  # wait a bit to ensure the agent is running
openshift-install agent wait-for install-complete --dir $ASSETS_DIR $opts
ret=$?
[ "$DEBUG_ABA" ] && echo "[ABA] openshift-install returned: $ret" >&2

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
		echo_red "[ABA] Error: Something went wrong with the installation.  Fix the problem and try again!" >&2
		[ "${wait_for_exit_reasons[$ret]}" ] && echo_yellow "[ABA] Reason: '${wait_for_exit_reasons[$ret]} ($ret)'" || echo_yellow "[ABA] Reason: 'Unknown ($ret)'"

		exit $ret
	fi
else
	echo 
	aba_info_ok "The cluster has been successfully installed!"
	aba_info_ok "Run '. <(aba shell)' to access the cluster using the kubeconfig file (auth cert), or"
	aba_info_ok "Run '. <(aba login)' to log into the cluster using kubeadmin's password."
	[ -f regcreds/pull-secret-mirror.json ] && \
		aba_info_ok "Run 'aba day2' to connect this cluster's OperatorHub to your mirror registry (run after adding any operators to your mirror)." && \
		aba_info_ok "Run 'aba day2-osus' to configure the OpenShift Update Service."
	aba_info_ok "Run 'aba day2-ntp' to configure NTP on this cluster."
	aba_info_ok "Run 'aba info' to view this information again."
	aba_info_ok "Run 'aba help' and 'aba -h' for more options."

	[ ! -f ~/.aba/.first_cluster_success ] && echo && echo_yellow "Well done! You've installed your first cluster using Aba! Please consider giving our project a star to let us know at: https://github.com/sjbylo/aba  Thank you! :)" && touch ~/.aba/.first_cluster_success || true
fi

exit 0
