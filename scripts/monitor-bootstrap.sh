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
echo =================================================================================

opts=
[ "$DEBUG_ABA" ] && opts="--log-level debug"
echo_yellow "Running: openshift-install agent wait-for bootstrap-complete --dir $ASSETS_DIR"
openshift-install agent wait-for bootstrap-complete --dir $ASSETS_DIR $opts
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
		echo_red "Something went wrong with the bootstrap.  Fix the problem and try again!" >&2
		[ "${wait_for_exit_reasons[$ret]}" ] && echo_yellow "Reason: '${wait_for_exit_reasons[$ret]} ($ret)'" || echo_yellow "Reason: 'Unknown ($ret)'"

		exit $ret
	fi
fi

