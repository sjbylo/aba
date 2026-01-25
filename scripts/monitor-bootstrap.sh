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

[ ! -f $ASSETS_DIR/rendezvousIP ] && aba_abort "Error: $ASSETS_DIR/rendezvousIP file missing.  Run 'aba iso' to create it."

[ "$no_proxy" ] && no_proxy="$(cat $ASSETS_DIR/rendezvousIP),$no_proxy"   # Needed since we're using the IP address to access
[ "$no_proxy" ] && aba_debug "Using: no_proxy=$no_proxy  opts=$opts"

# Ensure openshift-install is available (wait for background download/install)
ensure_openshift_install >/dev/null

echo_yellow "[ABA] Running: openshift-install agent wait-for bootstrap-complete --dir $ASSETS_DIR"


openshift-install agent wait-for bootstrap-complete --dir $ASSETS_DIR $opts
ret=$?
aba_debug openshift-install returned: $ret 

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
		echo_red "[ABA] Something went wrong with the bootstrap.  Fix the problem and try again!" >&2
		[ "${wait_for_exit_reasons[$ret]}" ] && echo_yellow "[ABA] Reason: '${wait_for_exit_reasons[$ret]} ($ret)'" || echo_yellow "[ABA] Reason: 'Unknown ($ret)'"

		exit $ret
	fi
fi

