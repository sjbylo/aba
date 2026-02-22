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
if ! ensure_openshift_install >/dev/null; then
	error_msg=$(get_task_error "$TASK_OPENSHIFT_INSTALL")
	aba_abort "Failed to install openshift-install:\n$error_msg"
fi

echo_yellow "[ABA] Running: openshift-install agent wait-for install-complete --dir $ASSETS_DIR"

#sleep 60  # wait a bit to ensure the agent is running
openshift-install agent wait-for install-complete --dir $ASSETS_DIR $opts
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

# ret = 8 means openshift-install was interrupted (e.g. Ctrl-c), for that we don't want to show any errors. 
[ $ret -eq 8 ] && exit 0

if [ $ret -ne 0 ]; then
	echo 
	echo_red "[ABA] Error: Something went wrong with the installation.  Fix the problem and try again!" >&2
	[ "${wait_for_exit_reasons[$ret]}" ] && echo_yellow "[ABA] Reason: '${wait_for_exit_reasons[$ret]} ($ret)'" || echo_yellow "[ABA] Reason: 'Unknown ($ret)'"

	exit $ret
fi

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

if [ ! -f ~/.aba/.first_cluster_success ]; then
	_bdr=$(printf '═%.0s' $(seq 1 64))
	_g=$(tput setaf 10 2>/dev/null)
	_r=$(tput sgr0 2>/dev/null)
	_boxl() { printf "  ${_g}║${_r}  %-62s${_g}║${_r}" "$1"; }
	_boxc() { printf "  ${_g}║${_r}  $(tput setaf "$1" 2>/dev/null)%-62s${_r}${_g}║${_r}" "$2"; }
	echo
	echo_bright_green  "  ╔${_bdr}╗"
	echo               "$(_boxl '')"
	echo               "$(_boxc 15 'Congratulations!')"
	echo               "$(_boxc 15 "You've installed your first OpenShift cluster using Aba!")"
	echo               "$(_boxl '')"
	echo               "$(_boxc 15 'Please consider giving our project a star to let us know:')"
	echo               "$(_boxc 14 'https://github.com/sjbylo/aba')"
	echo               "$(_boxl '')"
	echo               "$(_boxc 11 'Thank you! :)')"
	echo               "$(_boxl '')"
	echo_bright_green  "  ╚${_bdr}╝"
	echo

	touch ~/.aba/.first_cluster_success
fi

exit 0
